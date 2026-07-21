#!/usr/bin/env python3
"""Bounded, fail-closed osxphotos completeness check."""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time

COMPLETE = 0
INCOMPLETE = 10
UNAVAILABLE = 11
TOOL_ERROR = 12
MALFORMED = 13
TIMED_OUT = 14


def last_line(output: str) -> str:
    lines = output.splitlines()
    return lines[-1].strip() if lines else ""


def stop_process_group(process: subprocess.Popen[str], grace: float) -> str:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    # Keep the group leader unreaped during the grace period so its process-group
    # ID cannot be reused. Kill the group even if the leader exited promptly: a
    # detached child may have closed our output pipe and ignored SIGTERM.
    time.sleep(grace)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    output, _ = process.communicate()
    return output


def run(args: argparse.Namespace) -> int:
    executable = shutil.which(args.osxphotos)
    if executable is None:
        print(f"WARN photos-gate: osxphotos unavailable ({args.osxphotos})")
        return UNAVAILABLE

    command = [
        executable,
        "query",
        "--library",
        args.library,
        "--missing",
        "--not-syndicated",
        "--not-shared",
        "--count",
        "--mute",
    ]
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
    except OSError as error:
        print(f"WARN photos-gate: could not start osxphotos: {error}")
        return TOOL_ERROR

    try:
        output, _ = process.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        output = stop_process_group(process, args.kill_grace)
        detail = last_line(output)
        suffix = f": {detail}" if detail else ""
        print(f"WARN photos-gate: osxphotos timed out after {args.timeout:g}s{suffix}")
        return TIMED_OUT

    detail = last_line(output)
    if process.returncode != 0:
        suffix = f": {detail}" if detail else ""
        print(f"WARN photos-gate: osxphotos failed (rc={process.returncode}){suffix}")
        return TOOL_ERROR
    if not detail.isdecimal():
        shown = detail or "<empty>"
        print(f"WARN photos-gate: malformed osxphotos count: {shown}")
        return MALFORMED

    missing = int(detail)
    if missing > args.missing_max:
        print(
            f"photos-gate: {missing} personal originals NOT on disk "
            f"(> {args.missing_max})"
        )
        return INCOMPLETE

    print(
        "photos-gate: all personal originals present "
        f"({missing} missing, threshold {args.missing_max})"
    )
    return COMPLETE


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--osxphotos", required=True)
    parser.add_argument("--library", required=True)
    parser.add_argument("--missing-max", type=int, default=0)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--kill-grace", type=float, default=2.0)
    args = parser.parse_args()
    if args.missing_max < 0 or args.timeout <= 0 or args.kill_grace <= 0:
        parser.error("limits must be positive (missing-max may be zero)")
    return args


if __name__ == "__main__":
    sys.exit(run(parse_args()))
