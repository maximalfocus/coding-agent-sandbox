#!/usr/bin/env bash
# Regression coverage for the local-terminal clipboard boundary (issues #48 / #55).
#
# The property under test is NOT "the clipboard is never written" — that removed select-to-copy
# along with the vulnerability. It is: a clipboard write reaches the host ONLY when it can be tied
# to something the human at the host keyboard just did, and OSC 52 bytes never reach the terminal.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILTER="$ROOT/scripts/terminal/osc52-filter.py"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$FILTER" ] || fail 'OSC 52 gate is missing'
[ ! -e "$ROOT/scripts/terminal/herdr-pty-bridge.py" ] \
    || fail 'the unconditional host-clipboard bridge must not return'

# The launcher must never write the clipboard itself; only the gate may, and only under its rules.
if grep -Eq 'pbcopy|wl-copy|xclip|Set-Clipboard' "$ROOT/shell.sh"; then
    fail 'shell.sh must not invoke a native clipboard writer directly'
fi

grep -Fq 'exec python3 scripts/terminal/osc52-filter.py "${command[@]}"' "$ROOT/shell.sh" \
    || fail 'shell.sh must route terminal output through the OSC 52 gate'

# The gate is only usable if its policy is discoverable; an undocumented mode is an unset mode.
for mode in gesture confirm off; do
    grep -Fq "\`$mode\`" "$ROOT/README.md" \
        || fail "README.md must document the SANDBOX_CLIPBOARD '$mode' mode"
done
grep -Fq 'SANDBOX_CLIPBOARD' "$ROOT/README.md" \
    || fail 'README.md must name the SANDBOX_CLIPBOARD setting'
grep -Fq 'SANDBOX_CLIPBOARD' "$ROOT/SECURITY.md" \
    || fail 'SECURITY.md must describe the local-terminal clipboard rule it now enforces'

# --- byte containment: no OSC 52 sequence may reach the host terminal, in any mode ----------------
SANDBOX_CLIPBOARD_QUIET=1 python3 - "$FILTER" <<'PY'
import importlib.util
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("osc52_filter", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

forwarded = bytearray()
module.os.write = lambda _fd, data: forwarded.extend(data) or len(data)
module.copy_to_host = lambda data: True
module.sys.stdout = type("Stdout", (), {"fileno": lambda self: 1, "flush": lambda self: None})()

# Fragmented prefixes and payloads, both standard terminators, the 8-bit C1 form, a readback query,
# and an unterminated attack. Only ordinary output may reach the host terminal.
chunks = [
    b"before:",
    b"\x1b]5",
    b"2;c;YXBwbGljYXRpb24tY29udHJvbGxlZA==\x07",
    b"middle:",
    b"\x1b]52;;c2VsZWN0aW9uLWltcG9zdG9y\x1b",
    b"\\",
    b"after:",
    b"\x9d52;c;YzEtaW5qZWN0aW9u\x9c",
    b"query:",
    b"\x1b]52;c;?\x07",
    b"other-osc:\x1b]5",
    b"1;not-a-clipboard-command\x07",
    b"tail:",
    b"\x1b]52;c;dW50ZXJtaW5hdGVk",
]
for chunk in chunks:
    module.forward_filtered_output(chunk)

expected = b"before:middle:after:query:other-osc:\x1b]51;not-a-clipboard-command\x07tail:"
if bytes(forwarded) != expected:
    raise SystemExit(f"FAIL: unexpected forwarded output: {bytes(forwarded)!r}")
if not module.inside_osc52:
    raise SystemExit("FAIL: unterminated OSC 52 was not retained in the discard state")
PY

# --- gate decisions: who is allowed to move the payload onto the host clipboard -------------------
SANDBOX_CLIPBOARD_QUIET=1 python3 - "$FILTER" <<'PY'
import base64
import importlib.util
import pathlib
import sys

path = pathlib.Path(sys.argv[1])


def load(mode="gesture", **env):
    """Fresh module instance — the mode constants are resolved from the environment at import.

    Every knob is restated on each load: these are process-wide, so a value left behind by an
    earlier case would silently change the one under test.
    """
    import os
    os.environ["SANDBOX_CLIPBOARD"] = mode
    os.environ["SANDBOX_CLIPBOARD_QUIET"] = "1"
    os.environ["SANDBOX_CLIPBOARD_WINDOW"] = "3.0"
    os.environ["SANDBOX_CLIPBOARD_OFFER_TTL"] = "10.0"
    for key, value in env.items():
        os.environ[key] = value
    spec = importlib.util.spec_from_file_location("osc52_filter_" + mode, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.copied = []
    module.copy_to_host = lambda data: module.copied.append(data) or True
    module.os.write = lambda _fd, data: len(data)
    module.sys.stdout = type(
        "Stdout", (), {"fileno": lambda self: 1, "flush": lambda self: None}
    )()
    return module


def osc52(text):
    return b"\x1b]52;c;" + base64.b64encode(text) + b"\x07"


MOUSE_RELEASE = b"\x1b[<0;40;12m"
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


# 1. gesture mode: a write right after a host mouse-button release IS the selection you just made.
m = load("gesture")
m.filter_input(MOUSE_RELEASE)
m.forward_filtered_output(osc52(b"selected-text"))
check(m.copied == [b"selected-text"], "gesture mode did not honour a write following a mouse release")
check(m.offer is None, "an honoured write must not also leave a pending offer")

# 2. gesture mode: unattended output — the #48 attack — must NOT reach the clipboard.
m = load("gesture")
m.forward_filtered_output(osc52(b"rm -rf ~ #injected"))
check(m.copied == [], "unattended OSC 52 reached the host clipboard")
check(m.offer is not None, "a blocked write should be offered for confirmation")

# 3. ...and the confirm chord applies it, consuming the chord instead of passing it to the container.
forwarded = m.filter_input(b"a" + m.CHORD + b"b")
check(m.copied == [b"rm -rf ~ #injected"], "the confirm chord did not apply the held payload")
check(forwarded == b"ab", f"the confirm chord leaked to the container: {forwarded!r}")
check(m.offer is None, "the offer must be consumed once confirmed")

# 4. an expired offer is dead: the chord neither copies nor is swallowed.
m = load("gesture", SANDBOX_CLIPBOARD_OFFER_TTL="0")
m.forward_filtered_output(osc52(b"stale"))
forwarded = m.filter_input(m.CHORD)
check(m.copied == [], "an expired offer was still applied")
check(forwarded == m.CHORD, "the chord must pass through once no offer is live")

# 5. a stale gesture does not authorise a later write.
m = load("gesture", SANDBOX_CLIPBOARD_WINDOW="0")
m.filter_input(MOUSE_RELEASE)
m.forward_filtered_output(osc52(b"too-late"))
check(m.copied == [], "a write outside the gesture window was auto-accepted")

# 6. confirm mode never auto-accepts, even directly after a gesture.
m = load("confirm")
m.filter_input(MOUSE_RELEASE)
m.forward_filtered_output(osc52(b"selected-text"))
check(m.copied == [], "confirm mode auto-accepted a write")
check(m.offer is not None, "confirm mode should offer the write")

# 7. off mode discards everything, gesture or not.
m = load("off")
m.filter_input(MOUSE_RELEASE)
m.forward_filtered_output(osc52(b"selected-text"))
check(m.copied == [] and m.offer is None, "off mode let a clipboard write through")

# 8. a clipboard READ query is never honoured in any mode — it would leak the host clipboard.
for mode in ("gesture", "confirm", "off"):
    m = load(mode)
    m.filter_input(MOUSE_RELEASE)
    m.forward_filtered_output(b"\x1b]52;c;?\x07")
    check(m.copied == [] and m.offer is None, f"{mode} mode answered an OSC 52 read query")

# 9. malformed and oversized bodies are dropped rather than guessed at.
m = load("gesture")
m.filter_input(MOUSE_RELEASE)
m.forward_filtered_output(b"\x1b]52;c;!!!not-base64!!!\x07")
check(m.copied == [], "a malformed payload was copied")
m = load("gesture")
m.filter_input(MOUSE_RELEASE)
m.forward_filtered_output(b"\x1b]52;c;" + b"QUFB" * (3 * 1024 * 1024) + b"\x07")
check(m.copied == [], "an oversized payload was copied")

# 10. the gesture tracker survives a mouse report split across two host reads.
m = load("gesture")
m.filter_input(MOUSE_RELEASE[:5])
m.filter_input(MOUSE_RELEASE[5:])
m.forward_filtered_output(osc52(b"split-report"))
check(m.copied == [b"split-report"], "a mouse release split across reads was not detected")

if failures:
    for message in failures:
        print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)
PY

# --- the real nested-PTY path: hostile output reaches neither the terminal nor the clipboard ------
python3 - "$FILTER" <<'PY'
import errno
import os
import pathlib
import pty
import select
import subprocess
import sys
import tempfile

filter_path = pathlib.Path(sys.argv[1])
marker = tempfile.NamedTemporaryFile(prefix="osc52-clip-", delete=False)
marker.close()

# A fake pbcopy on PATH: if the gate ever writes the clipboard unattended, this file gets content.
bindir = tempfile.mkdtemp()
pbcopy = pathlib.Path(bindir, "pbcopy")
pbcopy.write_text(f"#!/bin/sh\ncat >> {marker.name}\n")
pbcopy.chmod(0o755)

master_fd, slave_fd = pty.openpty()
payload = b"before-pty\x1b]52;c;cHR5LWluamVjdGlvbg==\x07after-pty\n"
child_code = "import os,sys; os.write(sys.stdout.fileno(), " + repr(payload) + ")"
# Notices are suppressed so this case can assert on raw byte containment: the held payload is
# deliberately previewed on the status line, which is not the same as it escaping as output.
environment = dict(
    os.environ,
    PATH=bindir + os.pathsep + os.environ.get("PATH", ""),
    SANDBOX_CLIPBOARD="gesture",
    SANDBOX_CLIPBOARD_QUIET="1",
)
environment.pop("DISPLAY", None)
environment.pop("WAYLAND_DISPLAY", None)
process = subprocess.Popen(
    [sys.executable, str(filter_path), sys.executable, "-c", child_code],
    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, close_fds=True, env=environment,
)
os.close(slave_fd)
captured = bytearray()
while True:
    readable, _, _ = select.select([master_fd], [], [], 5)
    if not readable:
        process.kill()
        raise SystemExit("FAIL: timed out waiting for the PTY gate")
    try:
        chunk = os.read(master_fd, 65536)
    except OSError as exc:
        if exc.errno == errno.EIO:
            break
        raise
    if not chunk:
        break
    captured.extend(chunk)
os.close(master_fd)
if process.wait(timeout=5) != 0:
    raise SystemExit(f"FAIL: PTY gate exited nonzero: {bytes(captured)!r}")
if b"before-pty" not in captured or b"after-pty" not in captured:
    raise SystemExit(f"FAIL: ordinary PTY output was lost: {bytes(captured)!r}")
if b"pty-injection" in captured or b"\x1b]52;" in captured:
    raise SystemExit(f"FAIL: OSC 52 escaped the PTY gate: {bytes(captured)!r}")
if pathlib.Path(marker.name).read_bytes():
    raise SystemExit("FAIL: unattended OSC 52 was written to the host clipboard")
PY

# --- with notices ON: ordinary output survives and the notice is ordered after it ------------------
python3 - "$FILTER" <<'PY'
import errno, os, pathlib, pty, select, subprocess, sys, tempfile

filter_path = pathlib.Path(sys.argv[1])
bindir = tempfile.mkdtemp()
pbcopy = pathlib.Path(bindir, "pbcopy")
pbcopy.write_text("#!/bin/sh\ncat >/dev/null\n")
pbcopy.chmod(0o755)

master_fd, slave_fd = pty.openpty()
# A held write (no gesture) announces itself. That notice must land AFTER the output the app had
# already emitted, not ahead of it: it is raised mid-parse, while that output is still buffered.
payload = b"BEFORE \x1b]52;c;aGVsZA==\x07AFTER "
child = "import os,sys; os.write(sys.stdout.fileno(), " + repr(payload) + ")"
environment = dict(
    os.environ,
    PATH=bindir + os.pathsep + os.environ.get("PATH", ""),
    SANDBOX_CLIPBOARD="gesture",
)
environment.pop("SANDBOX_CLIPBOARD_QUIET", None)
environment.pop("DISPLAY", None)
environment.pop("WAYLAND_DISPLAY", None)
process = subprocess.Popen(
    [sys.executable, str(filter_path), sys.executable, "-c", child],
    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, close_fds=True, env=environment,
)
os.close(slave_fd)
captured = bytearray()
while True:
    readable, _, _ = select.select([master_fd], [], [], 5)
    if not readable:
        process.kill()
        raise SystemExit("FAIL: timed out waiting for the notice case")
    try:
        chunk = os.read(master_fd, 65536)
    except OSError as exc:
        if exc.errno == errno.EIO:
            break
        raise
    if not chunk:
        break
    captured.extend(chunk)
os.close(master_fd)
process.wait(timeout=5)

before, after, note = captured.find(b"BEFORE"), captured.find(b"AFTER"), captured.find(b"Ctrl-")
if before < 0 or after < 0:
    raise SystemExit(f"FAIL: a notice swallowed surrounding output: {bytes(captured)!r}")
if note < 0:
    raise SystemExit(f"FAIL: a held write was not announced: {bytes(captured)!r}")
if not before < after < note:
    raise SystemExit(f"FAIL: the notice was not ordered after the output it followed: {bytes(captured)!r}")
if b"\x1b]52;" in captured:
    raise SystemExit(f"FAIL: OSC 52 escaped with notices enabled: {bytes(captured)!r}")
PY

# --- the launcher takes the gate path even where a native writer is present -----------------------
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$ISSUE48_LOG"
if [ "${1:-} ${2:-}" = "compose ps" ]; then printf 'claude-sandbox\n'; fi
SH
cat > "$TMP_DIR/bin/python3" <<'SH'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >> "$ISSUE48_LOG"
SH
cat > "$TMP_DIR/bin/pbcopy" <<'SH'
#!/usr/bin/env bash
printf 'pbcopy invoked\n' >> "$ISSUE48_LOG"
exit 97
SH
chmod +x "$TMP_DIR/bin/docker" "$TMP_DIR/bin/python3" "$TMP_DIR/bin/pbcopy"

export ISSUE48_LOG="$TMP_DIR/invocations.log"
PATH="$TMP_DIR/bin:/usr/bin:/bin" "$ROOT/shell.sh"
PATH="$TMP_DIR/bin:/usr/bin:/bin" "$ROOT/shell.sh" --shell

grep -Fq 'python3 scripts/terminal/osc52-filter.py docker compose exec -u node -w /workspace claude-sandbox herdr' "$ISSUE48_LOG" \
    || fail 'shell.sh did not launch Herdr through the gate'
grep -Fq 'python3 scripts/terminal/osc52-filter.py docker compose exec -u node -w /workspace claude-sandbox bash -l' "$ISSUE48_LOG" \
    || fail 'shell.sh did not launch the plain shell through the gate'
if grep -Fq 'pbcopy invoked' "$ISSUE48_LOG"; then
    fail 'shell.sh invoked the host clipboard writer itself'
fi

printf 'PASS: OSC 52 reaches the host clipboard only behind a host-side human gesture\n'
