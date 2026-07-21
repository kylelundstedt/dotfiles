#!/usr/bin/env python3
"""Acceptance tests for the bounded Photos completeness gate."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

GATE = Path(__file__).with_name("photos_gate.py")


class PhotosGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.fake = self.root / "osxphotos"
        self.child_pid_file = self.root / "child.pid"
        self.fake.write_text(
            f"""#!{sys.executable}
import os
import signal
import subprocess
import sys
import time

expected = [
    "query", "--library", "/tmp/Fake.photoslibrary", "--missing",
    "--not-syndicated", "--not-shared", "--count", "--mute",
]
if sys.argv[1:] != expected:
    print("unexpected arguments")
    raise SystemExit(9)

mode = os.environ["FAKE_OSXPHOTOS_MODE"]
if mode == "success":
    print("status text before final count")
    print("0")
elif mode == "incomplete":
    print("2")
elif mode == "error":
    print("removable volume permission denied")
    raise SystemExit(7)
elif mode == "malformed":
    print("not a count")
elif mode == "hang":
    child = subprocess.Popen([
        sys.executable,
        "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(os.environ["CHILD_PID_FILE"], "w") as handle:
        handle.write(str(child.pid))
    time.sleep(60)
"""
        )
        self.fake.chmod(0o755)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def invoke(
        self, mode: str, timeout: float = 2.0
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["FAKE_OSXPHOTOS_MODE"] = mode
        env["CHILD_PID_FILE"] = str(self.child_pid_file)
        return subprocess.run(
            [
                sys.executable,
                str(GATE),
                "--osxphotos",
                str(self.fake),
                "--library",
                "/tmp/Fake.photoslibrary",
                "--missing-max",
                "0",
                "--timeout",
                str(timeout),
                "--kill-grace",
                "0.2",
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=5,
        )

    def test_complete(self) -> None:
        result = self.invoke("success")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("all personal originals present", result.stdout)

    def test_incomplete(self) -> None:
        result = self.invoke("incomplete")
        self.assertEqual(result.returncode, 10, result.stdout)
        self.assertIn("2 personal originals NOT on disk", result.stdout)

    def test_tool_error(self) -> None:
        result = self.invoke("error")
        self.assertEqual(result.returncode, 12, result.stdout)
        self.assertIn("permission denied", result.stdout)

    def test_malformed_output(self) -> None:
        result = self.invoke("malformed")
        self.assertEqual(result.returncode, 13, result.stdout)
        self.assertIn("malformed osxphotos count", result.stdout)

    def test_missing_tool(self) -> None:
        self.fake.unlink()
        result = self.invoke("success")
        self.assertEqual(result.returncode, 11, result.stdout)
        self.assertIn("osxphotos unavailable", result.stdout)

    def test_timeout_kills_process_group(self) -> None:
        started = time.monotonic()
        result = self.invoke("hang", timeout=0.2)
        self.assertEqual(result.returncode, 14, result.stdout)
        self.assertLess(time.monotonic() - started, 2)
        self.assertIn("timed out", result.stdout)

        child_pid = int(self.child_pid_file.read_text())
        for _ in range(20):
            status = subprocess.run(
                ["ps", "-p", str(child_pid), "-o", "stat="],
                capture_output=True,
                text=True,
            ).stdout.strip()
            if not status or status.startswith("Z"):
                break
            time.sleep(0.05)
        self.assertTrue(
            not status or status.startswith("Z"), f"child still running: {status}"
        )


if __name__ == "__main__":
    unittest.main()
