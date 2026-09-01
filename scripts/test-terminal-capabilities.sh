#!/usr/bin/env bash
# Offline contract/wiring checks for the behavioural terminal verifier.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOC="$ROOT/docs/terminal-capabilities.md"
VERIFY="$ROOT/scripts/verify-terminal-capabilities.sh"
PROBE="$ROOT/scripts/terminal/capability-probe.py"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok  %s\n' "$*"; }

[ -x "$VERIFY" ] || fail 'the behavioural verifier is missing or not executable'
[ -x "$PROBE" ] || fail 'the in-pane probe is missing or not executable'
[ -f "$DOC" ] || fail 'the terminal capability contract is missing'
ok 'the executable behavioural verifier and probe are present'

python3 - "$DOC" "$PROBE" <<'PY' || exit 1
import json, re, subprocess, sys

doc = open(sys.argv[1], encoding='utf-8').read()
schema = json.loads(subprocess.check_output([sys.argv[2], '--schema'], text=True))
paths = ('browser', 'posix-local', 'powershell-local')
for path in paths:
    count = len(re.findall(rf'^\| `{re.escape(path)}` \|', doc, re.M))
    assert count == 1, f'{path}: expected exactly one entry-path row, found {count}'
for heading in ('Terminal type at the pane', 'Colour depth', 'Geometry transport',
                'Keyboard input protocol', 'Evidence'):
    assert heading in doc, f'missing path field: {heading}'
for action in schema['actions']:
    count = len(re.findall(rf'^\| `{re.escape(action)}` \|', doc, re.M))
    assert count == 1, f'{action}: expected exactly one matrix row, found {count}'
documented_actions = tuple(re.findall(
    r'^\| `([^`]+)` \|', doc.split('## Fixed key matrix', 1)[1], re.M))
assert documented_actions == tuple(schema['actions']), \
    f'document claims actions the probe does not cover: {documented_actions}'
assert 'Shift+Enter' in doc and 'Alt+Enter' in doc and 'Alt+B' in doc
assert '**Unevaluated on this host**' in doc
print(f"ok  contract enumerates {len(paths)} paths and {len(schema['actions'])} probe actions")
PY

grep -Fq 'scripts/terminal/drive-posix-terminal.py' "$VERIFY" \
    || fail 'the verifier does not drive the POSIX terminal path'
grep -Fq 'scripts/terminal/drive-browser-terminal.js' "$VERIFY" \
    || fail 'the verifier does not drive the browser terminal path'
grep -Fq "UNEVALUATED powershell-local" "$VERIFY" \
    || fail 'the verifier does not report PowerShell as unevaluated'
grep -Fq 'shell.sh' "$ROOT/scripts/terminal/drive-posix-terminal.py" \
    || fail 'the POSIX driver bypasses shell.sh'
grep -Fq 'page.goto' "$ROOT/scripts/terminal/drive-browser-terminal.js" \
    || fail 'the browser driver does not enter through ttyd'
ok 'each supported path is probed or explicitly reported unevaluated'

for name in SANDBOX_CONFIG_VOLUME_NAME SANDBOX_CODEX_VOLUME_NAME SANDBOX_GH_VOLUME_NAME \
            SANDBOX_HERDR_VOLUME_NAME SANDBOX_AUDIT_VOLUME_NAME SANDBOX_WORKSPACE_VOLUME_NAME \
            SANDBOX_WORK_VOLUME_NAME SANDBOX_PERSONAL_VOLUME_NAME SANDBOX_CONTAINER_NAME; do
    grep -Fq "$name" "$VERIFY" || fail "the isolation boundary omits $name"
done
grep -Fq 'coding-agent-sandbox-*' "$VERIFY" \
    || fail 'the verifier does not reject a default volume name'
grep -Fq 'down -v --remove-orphans' "$VERIFY" \
    || fail 'the verifier does not tear down its disposable state'
grep -Fq 'wait_ttyd_log' "$VERIFY" \
    || fail 'the verifier does not wait for the real browser boundary to become ready'
grep -Fq -- '--network "$NETWORK"' "$VERIFY" \
    || fail 'the browser driver does not approach ttyd from the isolated Compose network'
grep -Fq 'docker cp "$ROOT/scripts/terminal/capability-probe.py"' "$VERIFY" \
    || fail 'the verifier does not copy only the probe into the isolated target'
if grep -Fq 'WORK_DIR="$ROOT"' "$VERIFY"; then
    fail 'the verifier exposes the repository checkout and its ignored files to the target'
fi
ok 'the behavioural verifier is isolated from operator containers and volumes'

grep -Fq 'COLORTERM` needs one qualification' "$DOC" \
    || fail 'the contract does not record that Herdr supplies COLORTERM'
if grep -Eq 'docker compose exec[^\n]*-e[^\n]*COLORTERM' "$ROOT/shell.sh"; then
    fail 'shell.sh grew a redundant COLORTERM export despite the measured Herdr behavior'
fi
ok 'COLORTERM is documented from pane evidence rather than inferred launcher configuration'

bash -n "$VERIFY"
python3 - "$PROBE" "$ROOT/scripts/terminal/drive-posix-terminal.py" <<'PY'
import sys
for path in sys.argv[1:]:
    compile(open(path, encoding='utf-8').read(), path, 'exec')
PY
ok 'new shell and Python sources parse'

printf 'PASS: terminal capability documentation and verifier wiring are internally complete.\n'
