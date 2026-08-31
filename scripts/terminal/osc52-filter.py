#!/usr/bin/env python3
"""Run a command in a PTY, gating OSC 52 clipboard writes on a host-side human gesture.

Background (issues #48 / #55). Herdr forwards a pane's own OSC 52 output with exactly the bytes it
uses for a real selection copy, so the byte stream alone cannot establish a trusted source. The
first implementation (`herdr-pty-bridge.py`) piped every OSC 52 payload straight to the host
clipboard, which let any program in the container silently overwrite it — paste injection. The
replacement discarded *every* OSC 52 sequence, which closed the hole but also removed
select-to-copy from the local terminal entirely.

This gate keeps the security property and gives copy back, by adding the one signal the byte
stream lacks: what the *human at the host keyboard* just did. The launcher already owns both
directions of the PTY, so it can see host input. A clipboard write is honoured only when it can be
tied to a person:

  gesture (default)  auto-accept a write that arrives within SANDBOX_CLIPBOARD_WINDOW seconds of a
                     mouse-button release typed on the host — i.e. the drag that just made the
                     selection. Any other write is held, not applied, and offered for confirmation.
  confirm            never auto-accept; every write is held and must be confirmed.
  off                discard every OSC 52 sequence (the post-#55 behaviour).

A held write is announced on the bottom row and applied only if the host presses the confirm chord
(Ctrl-] by default) within SANDBOX_CLIPBOARD_OFFER_TTL seconds. Unattended output therefore still
cannot reach the host clipboard, and OSC 52 *read* queries are always dropped so the container can
never learn what is already on it.
"""

import base64
import binascii
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time
import tty

PREFIXES = (b"\x1b]52;", b"\x9d52;")
TERMINATORS = (b"\x07", b"\x1b\\", b"\x9c")
# A clipboard payload is a selection, not a file transfer. Cap it so a hostile pane cannot grow the
# gate's memory without bound by opening OSC 52 and never terminating it.
MAX_BODY = 8 * 1024 * 1024

# SGR mouse reporting (DECSET 1006, what Herdr negotiates): a lowercase 'm' terminator is a button
# RELEASE. The legacy X10/normal form encodes release as button 3 -> Cb = 32 + 3, plus any of the
# shift/meta/ctrl modifier bits, hence the explicit byte set.
MOUSE_RELEASE_SGR = re.compile(rb"\x1b\[<\d{1,5};\d{1,5};\d{1,5}m")
MOUSE_RELEASE_LEGACY = re.compile(rb"\x1b\[M[\x23\x27\x2b\x2f\x33\x37\x3b\x3f]")
# Longest sequence either pattern can match, so a report split across two reads is still seen once.
INPUT_TAIL = 32


def _env_float(name: str, default: float) -> float:
    try:
        value = float(os.environ.get(name, ""))
    except ValueError:
        return default
    return value if value >= 0 else default


MODE = (os.environ.get("SANDBOX_CLIPBOARD") or "gesture").strip().lower()
if MODE not in ("gesture", "confirm", "off"):
    MODE = "gesture"
GESTURE_WINDOW = _env_float("SANDBOX_CLIPBOARD_WINDOW", 3.0)
OFFER_TTL = _env_float("SANDBOX_CLIPBOARD_OFFER_TTL", 10.0)
QUIET = bool(os.environ.get("SANDBOX_CLIPBOARD_QUIET"))

# Confirm chord, given as the letter of a Ctrl- combination (default Ctrl-]). It is swallowed only
# while an offer is live; at any other time it passes through to the container untouched.
_chord_letter = (os.environ.get("SANDBOX_CLIPBOARD_KEY") or "]").strip()[:1] or "]"
CHORD = bytes([ord(_chord_letter.upper()) & 0x1F])

pending = b""
inside_osc52 = False
after_escape = False
body = bytearray()
body_overflow = False

input_tail = b""
last_gesture = 0.0
offer = None  # (payload: bytes, deadline: float)

parsing_output = False
notice_queue = []

master_fd = -1
stdin_fd = 0


# --- host clipboard -------------------------------------------------------------------------------

def copy_to_host(data: bytes) -> bool:
    """Write data to the host's native clipboard. False when no writer is available."""
    if sys.platform == "darwin" and shutil.which("pbcopy"):
        command = ["pbcopy"]
    elif os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-copy"):
        command = ["wl-copy"]
    elif os.environ.get("DISPLAY") and shutil.which("xclip"):
        command = ["xclip", "-selection", "clipboard", "-in"]
    else:
        return False
    try:
        return subprocess.run(command, input=data, check=False).returncode == 0
    except OSError:
        return False


# --- host-terminal notices ------------------------------------------------------------------------

def window_size() -> tuple:
    try:
        rows, cols = struct.unpack("hhhh", fcntl.ioctl(stdin_fd, termios.TIOCGWINSZ, b"\0" * 8))[:2]
    except OSError:
        return 24, 80
    return (rows or 24), (cols or 80)


def preview(data: bytes) -> str:
    """A short, control-character-free rendering — the notice must not itself be an injection."""
    text = "".join(
        character if character.isprintable() else "·"
        for character in data.decode("utf-8", "replace")
    )
    return text[:57] + "…" if len(text) > 58 else text


def notice(message: str) -> None:
    """Paint one reverse-video line on the bottom row, leaving the cursor where the app left it.

    Herdr repaints over this on its next screen update, which is fine: the notice is transient by
    design and the confirm chord stays live for OFFER_TTL regardless of whether the line survives.
    """
    if QUIET:
        return
    # While output is being parsed the notice is queued instead of written: the surrounding output
    # is still in the parser's buffer, so writing now would put the notice ahead of text the app
    # emitted before it.
    if parsing_output:
        notice_queue.append(message)
        return
    rows, cols = window_size()
    text = message[: max(cols - 1, 1)]
    sequence = (
        b"\x1b7"                                  # save cursor + attributes
        + f"\x1b[{rows};1H".encode()              # bottom row, first column
        + b"\x1b[2K\x1b[7m"                       # clear the line, reverse video
        + text.encode("utf-8", "replace")
        + b"\x1b[0m\x1b8\a"                       # reset, restore cursor, bell
    )
    try:
        os.write(sys.stdout.fileno(), sequence)
    except OSError:
        pass


# --- OSC 52 decisions -----------------------------------------------------------------------------

def offer_is_live(now: float) -> bool:
    return offer is not None and now < offer[1]


def apply_clipboard(payload: bytes, source: str) -> None:
    if copy_to_host(payload):
        notice(f" clipboard ← sandbox ({source}, {len(payload)} bytes): {preview(payload)} ")
    else:
        notice(" clipboard write dropped — no pbcopy/wl-copy/xclip on this host ")


def handle_clipboard_write(raw: bytes) -> None:
    """Decide what a complete OSC 52 sequence body may do. Nothing here ever reaches the terminal."""
    global offer

    if body_overflow or b";" not in raw:
        return
    _selection, encoded = raw.split(b";", 1)
    # A '?' payload is a clipboard READ request. Answering it would hand the container whatever the
    # host has copied, so it is dropped in every mode — there is no gesture that makes it safe.
    if encoded.strip() == b"?":
        return
    try:
        payload = base64.b64decode(re.sub(rb"\s", b"", encoded), validate=True)
    except (binascii.Error, ValueError):
        return
    if not payload:
        return

    if MODE == "off":
        return

    now = time.monotonic()
    if MODE == "gesture" and (now - last_gesture) <= GESTURE_WINDOW:
        apply_clipboard(payload, "selection")
        return

    offer = (payload, now + OFFER_TTL)
    notice(
        f" sandbox wants the clipboard ({len(payload)} bytes): {preview(payload)} "
        f"— Ctrl-{_chord_letter.upper()} to accept "
    )


# --- output path ----------------------------------------------------------------------------------

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


def end_sequence() -> None:
    global inside_osc52, after_escape, body, body_overflow
    handle_clipboard_write(bytes(body))
    inside_osc52 = False
    after_escape = False
    body = bytearray()
    body_overflow = False


def absorb(chunk: bytes) -> None:
    global body_overflow
    if len(body) + len(chunk) > MAX_BODY:
        body_overflow = True
        del body[:]
        return
    body.extend(chunk)


def forward_filtered_output(data: bytes) -> None:
    """Forward ordinary output; capture OSC 52 sequences so none of their bytes reach the host."""
    global pending, inside_osc52, after_escape, parsing_output
    parsing_output = True
    data = pending + data
    pending = b""
    output = bytearray()

    while data:
        if inside_osc52:
            if after_escape:
                after_escape = False
                if data.startswith(b"\\"):
                    data = data[1:]
                    end_sequence()
                    continue
                absorb(b"\x1b")

            endings = [
                (position, len(terminator))
                for terminator in TERMINATORS
                if (position := data.find(terminator)) >= 0
            ]
            if not endings:
                if data.endswith(b"\x1b"):
                    after_escape = True
                    absorb(data[:-1])
                else:
                    absorb(data)
                data = b""
                break

            end, terminator_size = min(endings)
            absorb(data[:end])
            data = data[end + terminator_size :]
            end_sequence()
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

    parsing_output = False
    while notice_queue:
        notice(notice_queue.pop(0))


# --- input path -----------------------------------------------------------------------------------

def filter_input(data: bytes) -> bytes:
    """Track the human gesture, consume the confirm chord, forward everything else unchanged."""
    global input_tail, last_gesture, offer

    scan = input_tail + data
    if MOUSE_RELEASE_SGR.search(scan) or MOUSE_RELEASE_LEGACY.search(scan):
        last_gesture = time.monotonic()
    input_tail = scan[-INPUT_TAIL:]

    now = time.monotonic()
    if offer_is_live(now) and CHORD in data:
        payload = offer[0]
        offer = None
        apply_clipboard(payload, "confirmed")
        return data.replace(CHORD, b"", 1)
    if offer is not None and not offer_is_live(now):
        offer = None
    return data


# --- PTY plumbing ---------------------------------------------------------------------------------

def copy_window_size(source_fd: int, target_fd: int) -> None:
    try:
        size = fcntl.ioctl(source_fd, termios.TIOCGWINSZ, b"\0" * 8)
        fcntl.ioctl(target_fd, termios.TIOCSWINSZ, size)
    except OSError:
        pass


def main() -> int:
    global master_fd, stdin_fd

    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} command [args ...]", file=sys.stderr)
        return 2
    if not sys.stdout.isatty():
        os.execvp(sys.argv[1], sys.argv[1:])
    if not sys.stdin.isatty():
        print("refusing unfiltered terminal output: stdin is not a TTY", file=sys.stderr)
        return 1

    stdin_fd = sys.stdin.fileno()
    child_pid, master_fd = pty.fork()
    if child_pid == 0:
        os.execvp(sys.argv[1], sys.argv[1:])

    original = termios.tcgetattr(stdin_fd)
    copy_window_size(stdin_fd, master_fd)

    def resize(_signum=None, _frame=None):
        copy_window_size(stdin_fd, master_fd)
        try:
            os.kill(child_pid, signal.SIGWINCH)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGWINCH, resize)
    try:
        tty.setraw(stdin_fd)
        while True:
            readable, _, _ = select.select([stdin_fd, master_fd], [], [])
            if stdin_fd in readable:
                incoming = os.read(stdin_fd, 65536)
                if not incoming:
                    break
                forwarded = filter_input(incoming)
                if forwarded:
                    os.write(master_fd, forwarded)
            if master_fd in readable:
                try:
                    outgoing = os.read(master_fd, 65536)
                except OSError:
                    break
                if not outgoing:
                    break
                forward_filtered_output(outgoing)
    finally:
        termios.tcsetattr(stdin_fd, termios.TCSADRAIN, original)
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
