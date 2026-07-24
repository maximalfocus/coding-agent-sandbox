#!/usr/bin/env python3
"""Transparent PTY bridge that handles OSC 52 for terminals without clipboard support."""

import base64
import fcntl
import os
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import tty

PREFIX = b"\x1b]52;"
MAX_PENDING = 16 * 1024 * 1024
pending = b""


def copy_to_host(data: bytes) -> bool:
    if sys.platform == "darwin" and shutil.which("pbcopy"):
        command = ["pbcopy"]
    elif os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-copy"):
        command = ["wl-copy"]
    elif os.environ.get("DISPLAY") and shutil.which("xclip"):
        command = ["xclip", "-selection", "clipboard", "-in"]
    else:
        return False
    return subprocess.run(command, input=data, check=False).returncode == 0


def partial_prefix_length(data: bytes) -> int:
    for length in range(min(len(data), len(PREFIX) - 1), 0, -1):
        if data.endswith(PREFIX[:length]):
            return length
    return 0


def forward_output(data: bytes) -> None:
    """Strip complete OSC 52 writes, copy their payload, and forward everything else."""
    global pending
    pending += data
    output = bytearray()

    while pending:
        start = pending.find(PREFIX)
        if start < 0:
            keep = partial_prefix_length(pending)
            if keep:
                output.extend(pending[:-keep])
                pending = pending[-keep:]
            else:
                output.extend(pending)
                pending = b""
            break

        output.extend(pending[:start])
        bel = pending.find(b"\x07", start + len(PREFIX))
        st = pending.find(b"\x1b\\", start + len(PREFIX))
        endings = [(position, size) for position, size in ((bel, 1), (st, 2)) if position >= 0]
        if not endings:
            pending = pending[start:]
            if len(pending) > MAX_PENDING:
                output.extend(pending)
                pending = b""
            break

        end, terminator_size = min(endings)
        body = pending[start + len(PREFIX) : end]
        pending = pending[end + terminator_size :]
        try:
            _selection, encoded = body.split(b";", 1)
            if encoded != b"?":
                decoded = base64.b64decode(encoded, validate=True)
                if not copy_to_host(decoded):
                    output.extend(PREFIX + body + (b"\x07" if terminator_size == 1 else b"\x1b\\"))
        except (ValueError, base64.binascii.Error):
            output.extend(PREFIX + body + (b"\x07" if terminator_size == 1 else b"\x1b\\"))

    if output:
        os.write(sys.stdout.fileno(), output)


def copy_window_size(source_fd: int, target_fd: int) -> None:
    try:
        size = fcntl.ioctl(source_fd, termios.TIOCGWINSZ, b"\0" * 8)
        fcntl.ioctl(target_fd, termios.TIOCSWINSZ, size)
    except OSError:
        pass


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} command [args ...]", file=sys.stderr)
        return 2
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        os.execvp(sys.argv[1], sys.argv[1:])

    child_pid, master_fd = pty.fork()
    if child_pid == 0:
        os.execvp(sys.argv[1], sys.argv[1:])

    original = termios.tcgetattr(sys.stdin.fileno())
    copy_window_size(sys.stdin.fileno(), master_fd)

    def resize(_signum=None, _frame=None):
        copy_window_size(sys.stdin.fileno(), master_fd)
        try:
            os.kill(child_pid, signal.SIGWINCH)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGWINCH, resize)
    try:
        tty.setraw(sys.stdin.fileno())
        while True:
            readable, _, _ = select.select([sys.stdin.fileno(), master_fd], [], [])
            if sys.stdin.fileno() in readable:
                incoming = os.read(sys.stdin.fileno(), 65536)
                if not incoming:
                    break
                os.write(master_fd, incoming)
            if master_fd in readable:
                try:
                    outgoing = os.read(master_fd, 65536)
                except OSError:
                    break
                if not outgoing:
                    break
                forward_output(outgoing)
    finally:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, original)
        if pending:
            os.write(sys.stdout.fileno(), pending)
        try:
            os.close(master_fd)
        except OSError:
            pass

    _, status = os.waitpid(child_pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
