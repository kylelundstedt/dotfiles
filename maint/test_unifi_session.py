"""Offline PTY tests: synthetic credentials and a fake Codex, never a network."""

import errno
import json
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from pathlib import Path

LAUNCHER = Path(__file__).resolve().parent / ".local/bin/unifi-session"
FAKE_KEY = "synthetic-unifi-key-not-a-real-credential"


class Terminal:
    def __init__(self, command, env):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe(command[0], command, env)
        self.output = b""
        self.status = None

    def read_until(self, text):
        end = time.monotonic() + 8
        while text.encode() not in self.output:
            if time.monotonic() >= end or not self.read_once():
                raise AssertionError(f"Missing {text!r} in {self.output!r}")

    def read_once(self):
        if not select.select([self.fd], [], [], 0.1)[0]:
            return True
        try:
            data = os.read(self.fd, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return False
            raise
        self.output += data
        return bool(data)

    def send(self, text):
        os.write(self.fd, text.encode())

    def finish(self):
        end = time.monotonic() + 8
        while time.monotonic() < end:
            running, status = os.waitpid(self.pid, os.WNOHANG)
            if running:
                self.status = os.waitstatus_to_exitcode(status)
                while select.select([self.fd], [], [], 0)[0]:
                    if not self.read_once():
                        break
                return self.status
            self.read_once()
        raise AssertionError("Launcher did not exit")

    def close(self):
        if self.status is None:
            try:
                os.killpg(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(self.pid, 0)
        os.close(self.fd)


class UnifiSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.capture = self.root / "capture.json"
        self.options = self.root / "options.json"
        self.options.write_text("{}")
        self.env = {
            **{k: v for k, v in os.environ.items() if k != "XDG_CONFIG_HOME"},
            "HOME": str(self.home),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "TERM": "xterm",
        }
        # An executable Python fixture avoids invoking any real Codex installation.
        fixture = self.bin / "codex"
        fixture.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"options = json.load(open({str(self.options)!r}))\n"
            "if '--help' in sys.argv:\n"
            "    print('Codex CLI ' + ('--no-daemon' if not options.get('old') else ''))\n"
            "    sys.exit(0)\n"
            "result = {'args': sys.argv[1:], 'url': os.environ.get('UNIFI_URL'),\n"
            "          'tls': {k: os.environ.get(k) for k in\n"
            "                  ('UNIFI_CA_FILE', 'UNIFI_CONNECT_TO', 'UNIFI_TLS_ORIGIN')},\n"
            f"          'key_matches': os.environ.get('UNIFI_API_KEY') == {FAKE_KEY!r}}}\n"
            f"with open({str(self.capture)!r}, 'w') as f: json.dump(result, f)\n"
            "if options.get('wait'):\n"
            "    try: input('MOCK_CODEX_READY\\n')\n"
            "    except KeyboardInterrupt: sys.exit(130)\n"
            "sys.exit(options.get('status', 0))\n"
        )
        fixture.chmod(0o755)

    def start(self, args=(), *, trace=False):
        command = ["/bin/bash"]
        if trace:
            command.append("-x")
        command += [str(LAUNCHER), *args]
        terminal = Terminal(command, self.env)
        self.addCleanup(terminal.close)
        return terminal

    def supply_key(self, terminal, key=FAKE_KEY):
        terminal.read_until("UniFi API key (hidden; paste, then Return):")
        self.assertFalse(termios.tcgetattr(terminal.fd)[3] & termios.ECHO)
        terminal.send(key + "\n")

    def pin(self, subject="/CN=unifi.local"):
        pin_file = self.home / ".config/unifi-api/console.pem"
        pin_file.parent.mkdir(parents=True)
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                subject,
                "-keyout",
                str(self.root / "key.pem"),
                "-out",
                str(pin_file),
            ],
            check=True,
            capture_output=True,
        )
        return pin_file

    def assert_no_secret_output(self, terminal):
        self.assertNotIn(FAKE_KEY.encode(), terminal.output)

    def test_prompted_session_and_private_workspace(self):
        terminal = self.start()
        terminal.read_until("UniFi console LAN IP or hostname")
        terminal.send("192.0.2.1\n")
        self.supply_key(terminal)
        self.assertEqual(terminal.finish(), 0)
        result = json.loads(self.capture.read_text())
        self.assertTrue(result["key_matches"])
        self.assertEqual(result["url"], "https://192.0.2.1")
        args = result["args"]
        self.assertIn("--no-daemon", args)
        self.assertEqual(args[args.index("--sandbox") + 1], "read-only")
        self.assertEqual(args[args.index("--ask-for-approval") + 1], "on-request")
        configs = [args[i + 1] for i, value in enumerate(args) if value == "--config"]
        self.assertIn('approvals_reviewer="user"', configs)
        self.assertIn("allow_login_shell=false", configs)
        policy = next(c for c in configs if c.startswith("shell_environment_policy="))
        self.assertIn("ignore_default_excludes=true", policy)
        self.assertIn("exclude=[]", policy)
        self.assertIn("include_only=", policy)
        self.assertIn('"UNIFI_API_KEY"', policy)
        disabled = [args[i + 1] for i, value in enumerate(args) if value == "--disable"]
        self.assertCountEqual(disabled, ["shell_snapshot", "shell_snapshot_v2"])
        self.assertNotIn(FAKE_KEY, json.dumps(args))
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", args)
        workspace = self.home / "unifi-admin"
        self.assertEqual(workspace.stat().st_mode & 0o777, 0o700)
        instructions = workspace / "AGENTS.md"
        self.assertEqual(instructions.stat().st_mode & 0o777, 0o600)
        self.assertIn("Do not alter management access", instructions.read_text())
        self.assertNotIn(FAKE_KEY, instructions.read_text())
        self.assertEqual(sorted(p.name for p in workspace.iterdir()), ["AGENTS.md"])
        self.assertIn(b"Revoke/delete this API key", terminal.output)
        self.assert_no_secret_output(terminal)

    def test_pinned_certificate_routes_tls_name_to_console(self):
        pin_file = self.pin()
        terminal = self.start(["https://192.0.2.1"])
        terminal.read_until("TLS: pinned certificate for unifi.local")
        self.supply_key(terminal)
        self.assertEqual(terminal.finish(), 0)
        result = json.loads(self.capture.read_text())
        self.assertEqual(result["url"], "https://192.0.2.1")
        self.assertEqual(
            result["tls"],
            {
                "UNIFI_CA_FILE": str(pin_file),
                "UNIFI_CONNECT_TO": "unifi.local:443:192.0.2.1:443",
                "UNIFI_TLS_ORIGIN": "https://unifi.local:443",
            },
        )
        args = result["args"]
        policy = next(a for a in args if a.startswith("shell_environment_policy="))
        for name in ("UNIFI_CA_FILE", "UNIFI_CONNECT_TO", "UNIFI_TLS_ORIGIN"):
            self.assertIn(f'"{name}"', policy)
        self.assertIn('--connect-to "$UNIFI_CONNECT_TO"', args[-1])
        self.assertIn('"$UNIFI_API_KEY"', args[-1])
        instructions = (self.home / "unifi-admin/AGENTS.md").read_text()
        self.assertIn('--connect-to "$UNIFI_CONNECT_TO"', instructions)
        self.assertNotIn(FAKE_KEY, json.dumps(args))
        self.assert_no_secret_output(terminal)

    def test_pinned_certificate_with_port_and_ipv6(self):
        self.pin()
        terminal = self.start(["https://[2001:db8::1]:8443"])
        self.supply_key(terminal)
        self.assertEqual(terminal.finish(), 0)
        tls = json.loads(self.capture.read_text())["tls"]
        self.assertEqual(tls["UNIFI_CONNECT_TO"], "unifi.local:8443:[2001:db8::1]:8443")
        self.assertEqual(tls["UNIFI_TLS_ORIGIN"], "https://unifi.local:8443")

    def test_without_pin_tls_variables_not_passed(self):
        self.env["UNIFI_CA_FILE"] = "/inherited/not-pinned.pem"
        terminal = self.start(["https://192.0.2.1"])
        terminal.read_until("Run unifi-api --pin first.")
        self.supply_key(terminal)
        self.assertEqual(terminal.finish(), 0)
        result = json.loads(self.capture.read_text())
        self.assertEqual(set(result["tls"].values()), {None})
        self.assertNotIn("--connect-to", result["args"][-1])

    def test_unreadable_pin_rejected_before_credential_prompt(self):
        self.pin(subject="/O=No Common Name")
        terminal = self.start(["https://192.0.2.1"])
        self.assertEqual(terminal.finish(), 2)
        self.assertIn(b"re-run: unifi-api --pin", terminal.output)
        self.assertNotIn(b"UniFi API key", terminal.output)
        self.assertFalse(self.capture.exists())

    def test_existing_instructions_preserved(self):
        workspace = self.home / "unifi-admin"
        workspace.mkdir()
        instructions = workspace / "AGENTS.md"
        instructions.write_text("My existing instructions.\n")
        terminal = self.start(["https://udm.example.test:8443/"])
        self.supply_key(terminal)
        self.assertEqual(terminal.finish(), 0)
        self.assertEqual(instructions.read_text(), "My existing instructions.\n")
        self.assertEqual(
            json.loads(self.capture.read_text())["url"],
            "https://udm.example.test:8443",
        )

    def test_ipv6_origin(self):
        terminal = self.start(["https://[2001:db8::1]:443"])
        self.supply_key(terminal)
        self.assertEqual(terminal.finish(), 0)
        self.assertEqual(
            json.loads(self.capture.read_text())["url"],
            "https://[2001:db8::1]:443",
        )

    def test_codex_failure_keeps_exit_status_and_reminds(self):
        self.options.write_text('{"status": 17}')
        terminal = self.start(["192.0.2.1"])
        self.supply_key(terminal)
        self.assertEqual(terminal.finish(), 17)
        self.assertIn(b"Revoke/delete this API key", terminal.output)
        self.assert_no_secret_output(terminal)

    def test_trace_does_not_disclose_key(self):
        terminal = self.start(["192.0.2.1"], trace=True)
        self.supply_key(terminal)
        self.assertEqual(terminal.finish(), 0)
        self.assert_no_secret_output(terminal)

    def test_cancel_during_key_entry(self):
        terminal = self.start(["192.0.2.1"])
        terminal.read_until("UniFi API key (hidden; paste, then Return):")
        terminal.send("\x03")
        self.assertEqual(terminal.finish(), 130)
        self.assertFalse(self.capture.exists())
        self.assertIn(b"Revoke/delete this API key", terminal.output)
        self.assertTrue(termios.tcgetattr(terminal.fd)[3] & termios.ECHO)

    def test_cancel_at_address_prompt_reminds(self):
        terminal = self.start()
        terminal.read_until("UniFi console LAN IP or hostname")
        terminal.send("\x03")
        self.assertEqual(terminal.finish(), 130)
        self.assertFalse(self.capture.exists())
        self.assertIn(b"Revoke/delete this API key", terminal.output)

    def test_interrupt_running_codex(self):
        self.options.write_text('{"wait": true}')
        terminal = self.start(["192.0.2.1"])
        self.supply_key(terminal)
        terminal.read_until("MOCK_CODEX_READY")
        self.assertTrue(termios.tcgetattr(terminal.fd)[3] & termios.ECHO)
        terminal.send("\x03")
        self.assertEqual(terminal.finish(), 130)
        self.assertIn(b"Revoke/delete this API key", terminal.output)
        self.assert_no_secret_output(terminal)

    def test_eof_during_key_entry(self):
        terminal = self.start(["192.0.2.1"])
        terminal.read_until("UniFi API key (hidden; paste, then Return):")
        terminal.send("\x04")
        self.assertEqual(terminal.finish(), 2)
        self.assertFalse(self.capture.exists())
        self.assertIn(b"Revoke/delete this API key", terminal.output)
        self.assertTrue(termios.tcgetattr(terminal.fd)[3] & termios.ECHO)

    def test_terminated_session_reminds(self):
        self.options.write_text('{"wait": true}')
        terminal = self.start(["192.0.2.1"])
        self.supply_key(terminal)
        terminal.read_until("MOCK_CODEX_READY")
        os.killpg(terminal.pid, signal.SIGTERM)
        self.assertEqual(terminal.finish(), 143)
        self.assertIn(b"Revoke/delete this API key", terminal.output)
        self.assert_no_secret_output(terminal)

    def test_invalid_key_does_not_start_codex(self):
        for key in ("", "has whitespace"):
            with self.subTest(key=key):
                terminal = self.start(["192.0.2.1"])
                self.supply_key(terminal, key)
                self.assertEqual(terminal.finish(), 2)
                self.assertFalse(self.capture.exists())
                self.assertIn(b"Revoke/delete this API key", terminal.output)

    def test_invalid_origins_rejected_before_credential_prompt(self):
        for address in (
            "http://192.0.2.1",
            "https://user:password@udm.test",
            "https://udm.test/path",
            "https://udm.test?key=oops",
            "https://udm.test#fragment",
            "udm.test;echo",
            "udm.test:0",
            "udm.test:65536",
            "udm.test:123456",
            "--dangerously-bypass-approvals-and-sandbox",
        ):
            with self.subTest(address=address):
                terminal = self.start([address])
                self.assertEqual(terminal.finish(), 2)
                self.assertNotIn(b"UniFi API key (hidden", terminal.output)
                self.assertFalse(self.capture.exists())

    def test_old_codex_rejected_before_credential_prompt(self):
        self.options.write_text('{"old": true}')
        terminal = self.start(["192.0.2.1"])
        self.assertEqual(terminal.finish(), 2)
        self.assertIn(b"Update Codex CLI", terminal.output)
        self.assertNotIn(b"UniFi API key (hidden", terminal.output)

    def test_missing_codex_rejected(self):
        (self.bin / "codex").rename(self.bin / "not-codex")
        self.env["PATH"] = str(self.bin)
        terminal = self.start(["192.0.2.1"])
        self.assertEqual(terminal.finish(), 2)
        self.assertIn(b"Install Codex CLI", terminal.output)
        self.assertNotIn(b"UniFi API key (hidden", terminal.output)

    def test_workspace_symlink_rejected(self):
        target = self.home / "other"
        target.mkdir()
        (self.home / "unifi-admin").symlink_to(target, target_is_directory=True)
        terminal = self.start(["192.0.2.1"])
        self.assertEqual(terminal.finish(), 2)
        self.assertEqual(list(target.iterdir()), [])

    def test_instructions_symlink_rejected(self):
        workspace = self.home / "unifi-admin"
        workspace.mkdir()
        target = self.home / "other.md"
        target.write_text("untouched")
        (workspace / "AGENTS.md").symlink_to(target)
        terminal = self.start(["192.0.2.1"])
        self.assertEqual(terminal.finish(), 2)
        self.assertEqual(target.read_text(), "untouched")

    def test_noninteractive_input_rejected(self):
        result = subprocess.run(
            [str(LAUNCHER), "192.0.2.1"],
            input=FAKE_KEY,
            capture_output=True,
            text=True,
            env=self.env,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("interactive terminal", result.stderr)
        self.assertNotIn(FAKE_KEY, result.stdout + result.stderr)

    def test_help_does_not_require_terminal_or_create_files(self):
        result = subprocess.run(
            [str(LAUNCHER), "--help"],
            capture_output=True,
            text=True,
            env=self.env,
            check=False,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage: unifi-session", result.stdout)
        self.assertFalse((self.home / "unifi-admin").exists())

    def test_sourcing_refused(self):
        result = subprocess.run(
            ["/bin/bash", "-c", 'source "$1"', "test", str(LAUNCHER)],
            capture_output=True,
            text=True,
            env=self.env,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("do not source", result.stderr)


if __name__ == "__main__":
    unittest.main()
