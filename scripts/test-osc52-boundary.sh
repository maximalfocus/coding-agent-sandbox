#!/usr/bin/env bash
# Regression coverage for issue #48's local-terminal clipboard boundary.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILTER="$ROOT/scripts/terminal/osc52-filter.py"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$FILTER" ] || fail 'OSC 52 filter is missing'
[ ! -e "$ROOT/scripts/terminal/herdr-pty-bridge.py" ] \
    || fail 'the host-clipboard bridge must not remain available'

if grep -ERq 'pbcopy|wl-copy|xclip|Set-Clipboard' "$ROOT/shell.sh" "$FILTER"; then
    fail 'the POSIX local-terminal path must not invoke a native clipboard writer'
fi

grep -Fq 'exec python3 scripts/terminal/osc52-filter.py "${command[@]}"' "$ROOT/shell.sh" \
    || fail 'shell.sh must route terminal output through the OSC 52 filter'

python3 - "$FILTER" <<'PY'
import importlib.util
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("osc52_filter", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

forwarded = bytearray()
original_write = module.os.write
module.os.write = lambda _fd, data: forwarded.extend(data) or len(data)
original_stdout = module.sys.stdout
module.sys.stdout = type(
    "Stdout",
    (),
    {"fileno": lambda self: 1, "flush": lambda self: None},
)()

# Exercise fragmented prefixes and payloads, both standard terminators, the 8-bit C1 form,
# a readback query, and an unterminated attack. Only ordinary output may reach the host terminal.
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
module.os.write = original_write
module.sys.stdout = original_stdout
PY

# Exercise the actual nested-PTY path with a child that writes a hostile sequence. The payload and
# control bytes must not emerge on the outer terminal, while adjacent ordinary output survives.
python3 - "$FILTER" <<'PY'
import errno
import os
import pathlib
import pty
import select
import subprocess
import sys

filter_path = pathlib.Path(sys.argv[1])
master_fd, slave_fd = pty.openpty()
payload = b"before-pty\x1b]52;c;cHR5LWluamVjdGlvbg==\x07after-pty\n"
child_code = "import os,sys; os.write(sys.stdout.fileno(), " + repr(payload) + ")"
process = subprocess.Popen(
    [sys.executable, str(filter_path), sys.executable, "-c", child_code],
    stdin=slave_fd,
    stdout=slave_fd,
    stderr=slave_fd,
    close_fds=True,
)
os.close(slave_fd)
captured = bytearray()
while True:
    readable, _, _ = select.select([master_fd], [], [], 5)
    if not readable:
        process.kill()
        raise SystemExit("FAIL: timed out waiting for the PTY filter")
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
    raise SystemExit(f"FAIL: PTY filter exited nonzero: {bytes(captured)!r}")
if b"before-pty" not in captured or b"after-pty" not in captured:
    raise SystemExit(f"FAIL: ordinary PTY output was lost: {bytes(captured)!r}")
if b"pty-injection" in captured or b"\x1b]52;" in captured:
    raise SystemExit(f"FAIL: OSC 52 escaped the PTY filter: {bytes(captured)!r}")
PY

# Prove the launcher takes the filter path even on a host where a native writer is present.
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
    || fail 'shell.sh did not launch Herdr through the filter'
grep -Fq 'python3 scripts/terminal/osc52-filter.py docker compose exec -u node -w /workspace claude-sandbox bash -l' "$ISSUE48_LOG" \
    || fail 'shell.sh did not launch the plain shell through the filter'
if grep -Fq 'pbcopy invoked' "$ISSUE48_LOG"; then
    fail 'shell.sh invoked the host clipboard writer'
fi

printf 'PASS: application-originated OSC 52 cannot reach the POSIX host clipboard\n'
