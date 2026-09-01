#!/usr/bin/env python3
"""Drive the real POSIX launcher through a PTY for terminal capability verification."""

from __future__ import annotations

import argparse
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


SEPARATOR = b"\x1c"
ACTIONS = (
    b"cas", b"\r", b"\x03", b"\x1b[A", b"\x1b[B", b"\x1b[C", b"\x1b[D",
    b"\x1b[H", b"\x1b[F", b"\x1bb",
    b"\r",  # legacy xterm mode cannot distinguish Shift+Enter from Enter
    b"\x1b[1;5D", b"\x1b[1;5C", b"\x1b\r",
)


def set_size(fd: int, rows: int, cols: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def pump(fd: int, captured: bytearray, deadline: float, needle: bytes | None = None) -> bool:
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.25)
        if not readable:
            if needle is None and captured:
                return True
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            return False
        if not chunk:
            return False
        captured.extend(chunk)
        if len(captured) > 2_000_000:
            del captured[:-1_000_000]
        if needle and needle in captured:
            return True
    return needle is None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--probe", required=True)
    args = parser.parse_args()

    command = (
        f"python3 {args.probe} "
        f"--path posix-local --output {args.output} --ready {args.ready} --token {args.token}"
    )
    ready = f"CAPABILITY_READY:{args.token}".encode()
    done = f"CAPABILITY_DONE:{args.token}".encode()
    failed = f"CAPABILITY_FAIL:{args.token}".encode()
    captured = bytearray()

    pid, master = pty.fork()
    if pid == 0:
        os.chdir(args.root)
        environment = os.environ.copy()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        os.execve(os.path.join(args.root, "shell.sh"), ["./shell.sh"], environment)

    status = 1
    try:
        set_size(master, 47, 133)
        pump(master, captured, time.monotonic() + 20)
        os.write(master, command.encode() + b"\r")
        if not pump(master, captured, time.monotonic() + 25, ready):
            print("POSIX launcher never reached the probe pane", file=sys.stderr)
            return 1

        for action in ACTIONS:
            os.write(master, action + SEPARATOR)

        set_size(master, 61, 171)
        try:
            os.kill(pid, signal.SIGWINCH)
        except ProcessLookupError:
            pass
        os.write(master, b"r" + SEPARATOR)

        if not pump(master, captured, time.monotonic() + 25, done):
            detail = "probe failed" if failed in captured else "probe did not finish"
            print(f"POSIX launcher {detail}", file=sys.stderr)
            return 1
        status = 0
        return 0
    finally:
        try:
            os.close(master)
        except OSError:
            pass
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        if status != 0 and captured:
            print(bytes(captured[-2000:]).decode("utf-8", "replace"), file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
