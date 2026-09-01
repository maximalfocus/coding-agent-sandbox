#!/usr/bin/env python3
"""Record bytes and terminal facts from inside an isolated Herdr pane.

This is not an operator-facing input channel. The host-side verifier starts it by typing through an
existing terminal entry path, then separates the fixed actions with ASCII FS (0x1c). Results stay
in /tmp or the verifier's disposable workspace volume.
"""

from __future__ import annotations

import argparse
import curses
import json
import os
import select
import sys
import tempfile
import termios
import time
import tty


ACTIONS = (
    "ordinary-text",
    "enter",
    "ctrl-c",
    "arrow-up",
    "arrow-down",
    "arrow-right",
    "arrow-left",
    "home",
    "end",
    "alt-b",
    "shift-enter",
    "ctrl-arrow-left",
    "ctrl-arrow-right",
    "alt-enter",
    "resize-marker",
)
SEPARATOR = b"\x1c"


def terminal_size(fd: int) -> dict[str, int]:
    size = os.get_terminal_size(fd)
    return {"rows": size.lines, "cols": size.columns}


def advertised_colours() -> int:
    try:
        curses.setupterm(fd=sys.stdout.fileno())
        return int(curses.tigetnum("colors"))
    except (curses.error, OSError, ValueError):
        return -1


def atomic_json(path: str, value: object) -> None:
    directory = os.path.dirname(path) or "."
    fd, temporary = tempfile.mkstemp(prefix=".capability-probe-", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output")
    parser.add_argument("--ready")
    parser.add_argument("--path", choices=("browser", "posix-local"))
    parser.add_argument("--token")
    parser.add_argument("--schema", action="store_true")
    args = parser.parse_args()

    if args.schema:
        print(json.dumps({"actions": ACTIONS, "separator_hex": SEPARATOR.hex()}))
        return 0
    if not all((args.output, args.ready, args.path, args.token)):
        parser.error("--output, --ready, --path, and --token are required")
    allowed = ("/tmp/", "/workspace/.terminal-capability-probe/")
    if not args.output.startswith(allowed) or not args.ready.startswith(allowed):
        parser.error("probe state must stay in disposable verifier storage")

    fd = sys.stdin.fileno()
    if not os.isatty(fd):
        print("capability probe requires a real terminal pane", file=sys.stderr)
        return 2

    original = termios.tcgetattr(fd)
    initial = terminal_size(fd)
    frames: list[bytes] = []
    pending = b""
    deadline = time.monotonic() + 45

    try:
        tty.setraw(fd)
        atomic_json(args.ready, {"path": args.path, "token": args.token})
        os.write(sys.stdout.fileno(), f"\r\nCAPABILITY_READY:{args.token}\r\n".encode())

        while len(frames) < len(ACTIONS):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"received {len(frames)} of {len(ACTIONS)} framed actions")
            readable, _, _ = select.select([fd], [], [], min(remaining, 1.0))
            if not readable:
                continue
            chunk = os.read(fd, 4096)
            if not chunk:
                raise EOFError("terminal input closed before all actions arrived")
            pending += chunk
            while SEPARATOR in pending and len(frames) < len(ACTIONS):
                frame, pending = pending.split(SEPARATOR, 1)
                frames.append(frame)

        resized = terminal_size(fd)
        resize_deadline = time.monotonic() + 10
        while resized == initial and time.monotonic() < resize_deadline:
            time.sleep(0.05)
            resized = terminal_size(fd)

        result = {
            "path": args.path,
            "term": os.environ.get("TERM", ""),
            "colorterm": os.environ.get("COLORTERM", ""),
            "advertised_colours": advertised_colours(),
            "initial_geometry": initial,
            "resized_geometry": resized,
            "actions": [
                {"name": name, "hex": frame.hex(), "bytes": len(frame)}
                for name, frame in zip(ACTIONS, frames, strict=True)
            ],
        }
        atomic_json(args.output, result)
        os.write(sys.stdout.fileno(), f"\r\nCAPABILITY_DONE:{args.token}\r\n".encode())
        return 0
    except (EOFError, OSError, TimeoutError) as error:
        os.write(sys.stdout.fileno(), f"\r\nCAPABILITY_FAIL:{args.token}:{error}\r\n".encode())
        return 1
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, original)


if __name__ == "__main__":
    raise SystemExit(main())
