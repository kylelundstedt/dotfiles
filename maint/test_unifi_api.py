"""Offline tests: fake op/curl/openssl and a synthetic password, never a network."""

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

WRAPPER = Path(__file__).resolve().parent / ".local/bin/unifi-api"
BASH = "/bin/bash" if Path("/bin/bash").exists() else "bash"
FAKE_PASSWORD = "synthetic-password-not-a-real-credential"

FAKE_CURL = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    opts, url, i = {}, None, 0
    while i < len(args):
        a = args[i]
        if a in ("-c", "-b", "-D", "-o", "-w", "-X", "-H", "--data", "--cacert",
                 "--resolve", "--noproxy", "--max-time"):
            opts.setdefault(a, []).append(args[i + 1])
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            url = a
            i += 1
    stdin = sys.stdin.read() if opts.get("--data") == ["@-"] else ""
    with open(os.environ["FAKE_LOG"], "a") as log:
        log.write(json.dumps({"argv": args, "url": url, "opts": opts, "stdin": stdin}) + "\\n")
    if url.endswith("/api/auth/login"):
        code = os.environ.get("FAKE_LOGIN_CODE", "200")
        with open(opts["-D"][0], "w") as hdr:
            hdr.write("HTTP/1.1 " + code + "\\r\\nX-CSRF-Token: synthetic-csrf\\r\\n\\r\\n")
        body = "{}"
    elif url.endswith("/api/auth/logout"):
        code, body = "200", ""
    else:
        code = "404" if "missing" in url else os.environ.get("FAKE_GET_CODE", "200")
        body = '{"data":["fake"]}'
    out = opts.get("-o", ["-"])[0]
    if out != "/dev/null":
        with open(out, "w") as f:
            f.write(body)
    if "-w" in opts:
        sys.stdout.write(code)
    """
)

FAKE_OP = textwrap.dedent(
    f"""\
    #!/bin/sh
    case "$4" in
        */username) echo agent-user ;;
        */password) echo '{FAKE_PASSWORD}' ;;
        *) exit 1 ;;
    esac
    """
)

FAKE_OPENSSL = "#!/bin/sh\necho 'subject=CN=unifi.local'\n"


class UnifiApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        fakebin = self.tmp / "bin"
        fakebin.mkdir()
        for name, body in (
            ("curl", FAKE_CURL),
            ("op", FAKE_OP),
            ("openssl", FAKE_OPENSSL),
        ):
            (fakebin / name).write_text(body)
            (fakebin / name).chmod(0o755)
        self.config = self.tmp / "config"
        self.log = self.tmp / "curl.log"
        jq_dir = os.path.dirname(shutil.which("jq"))
        self.env = {
            "PATH": f"{fakebin}:{jq_dir}:/usr/bin:/bin",
            "HOME": str(self.tmp),
            "XDG_CONFIG_HOME": str(self.config),
            "FAKE_LOG": str(self.log),
            "UNIFI_URL": "https://192.0.2.1",
        }

    def pin(self):
        (self.config / "unifi-api").mkdir(parents=True)
        (self.config / "unifi-api/console.pem").write_text("fake certificate\n")

    def run_wrapper(self, *args, **env):
        return subprocess.run(
            [BASH, str(WRAPPER), *args],
            check=False,
            env={**self.env, **env},
            capture_output=True,
            text=True,
            timeout=20,
        )

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_help(self):
        result = self.run_wrapper("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage: unifi-api PATH", result.stdout)

    def test_rejects_bad_paths_without_requests(self):
        self.pin()
        for path in ("proxy/x", "https://evil/x", "/a/../b", "/a b", "/a;b", "/a$(id)"):
            with self.subTest(path=path):
                result = self.run_wrapper(path)
                self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_rejects_bad_origin(self):
        self.pin()
        result = self.run_wrapper("/a", UNIFI_URL="http://192.0.2.1")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_requires_pinned_certificate(self):
        result = self.run_wrapper("/proxy/network/api/self/sites")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unifi-api --pin", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_get_signs_in_reads_and_signs_out(self):
        self.pin()
        result = self.run_wrapper("/proxy/network/api/self/sites")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '{"data":["fake"]}')

        login, get, logout = self.calls()
        self.assertTrue(login["url"].endswith("/api/auth/login"))
        self.assertEqual(
            json.loads(login["stdin"]),
            {"username": "agent-user", "password": FAKE_PASSWORD, "rememberMe": False},
        )
        self.assertEqual(
            get["url"], "https://unifi.local:443/proxy/network/api/self/sites"
        )
        self.assertNotIn("-X", get["opts"])
        self.assertNotIn("--data", get["opts"])
        self.assertEqual(get["opts"]["--resolve"], ["unifi.local:443:192.0.2.1"])
        self.assertTrue(logout["url"].endswith("/api/auth/logout"))
        self.assertEqual(logout["opts"]["-X"], ["POST"])
        self.assertIn("X-CSRF-Token: synthetic-csrf", logout["opts"]["-H"])

        for call in (login, get, logout):
            self.assertNotIn(FAKE_PASSWORD, " ".join(call["argv"]))
        self.assertFalse(Path(login["opts"]["-c"][0]).parent.exists())

    def test_refused_sign_in_stops_before_request(self):
        self.pin()
        result = self.run_wrapper(
            "/proxy/network/api/self/sites", FAKE_LOGIN_CODE="401"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sign-in refused (HTTP 401)", result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_rate_limited_sign_in_says_to_batch(self):
        self.pin()
        result = self.run_wrapper(
            "/proxy/network/api/self/sites", FAKE_LOGIN_CODE="429"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("rate-limited", result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_batch_signs_in_once_and_reports_each_path(self):
        self.pin()
        result = self.run_wrapper("/proxy/a", "/proxy/missing", "/proxy/b")
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 404 for /proxy/missing", result.stderr)
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(
            lines,
            [
                {"path": "/proxy/a", "status": 200, "body": {"data": ["fake"]}},
                {"path": "/proxy/missing", "status": 404, "body": {"data": ["fake"]}},
                {"path": "/proxy/b", "status": 200, "body": {"data": ["fake"]}},
            ],
        )
        urls = [call["url"] for call in self.calls()]
        self.assertEqual(sum(u.endswith("/api/auth/login") for u in urls), 1)
        self.assertTrue(urls[-1].endswith("/api/auth/logout"))
        self.assertEqual(len(urls), 5)

    def test_batch_validates_every_path_before_requests(self):
        self.pin()
        result = self.run_wrapper("/proxy/a", "/a/../b")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_pin_takes_no_other_arguments(self):
        self.assertEqual(self.run_wrapper("--pin", "/a").returncode, 2)

    def test_error_status_fails_and_still_signs_out(self):
        self.pin()
        result = self.run_wrapper(
            "/proxy/network/api/s/default/nope", FAKE_GET_CODE="403"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 403", result.stderr)
        self.assertTrue(self.calls()[-1]["url"].endswith("/api/auth/logout"))


if __name__ == "__main__":
    unittest.main()
