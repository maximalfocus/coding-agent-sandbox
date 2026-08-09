#!/usr/bin/env python3
"""Run a command in a PTY while removing OSC 52 clipboard control sequences."""

import fcntl
import os
import pty
import select
import signal
import sys
import termios
import tty

PREFIXES = (b"\x1b]52;", b"\x9d52;")
TERMINATORS = (b"\x07", b"\x1b\\", b"\x9c")

pending = b""
inside_osc52 = False
after_escape = False


def partial_prefix_length(data: bytes) -> int:
    """Return the longest suffix that could begin an OSC 52 prefix."""
    return max(
        (
            length
            for prefix in PREFIXES
            for length in range(1, len(prefix))
            if data.endswith(prefix[:length])
        ),
        default=0,
    )


def forward_filtered_output(data: bytes) -> None:
    """Forward ordinary output and discard complete or unterminated OSC 52 sequences."""
    global pending, inside_osc52, after_escape
    data = pending + data
    pending = b""
    output = bytearray()

    while data:
        if inside_osc52:
            if after_escape and data.startswith(b"\\"):
                inside_osc52 = False
                after_escape = False
                data = data[1:]
                continue
            after_escape = False

            endings = [
                (position, len(terminator))
                for terminator in TERMINATORS
                if (position := data.find(terminator)) >= 0
            ]
            if not endings:
                after_escape = data.endswith(b"\x1b")
                data = b""
                break

            end, terminator_size = min(endings)
            data = data[end + terminator_size :]
            inside_osc52 = False
            continue

        starts = [
            (position, prefix)
            for prefix in PREFIXES
            if (position := data.find(prefix)) >= 0
        ]
        if starts:
            start, prefix = min(starts, key=lambda match: match[0])
            output.extend(data[:start])
            data = data[start + len(prefix) :]
            inside_osc52 = True
            continue

        keep = partial_prefix_length(data)
        if keep:
            output.extend(data[:-keep])
            pending = data[-keep:]
        else:
            output.extend(data)
        data = b""

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
    if not sys.stdout.isatty():
        os.execvp(sys.argv[1], sys.argv[1:])
    if not sys.stdin.isatty():
        print("refusing unfiltered terminal output: stdin is not a TTY", file=sys.stderr)
        return 1

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
                forward_filtered_output(outgoing)
    finally:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, original)
        if pending and not inside_osc52:
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
