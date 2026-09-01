#!/usr/bin/env bash
# The repository checkout is host source state, not an uninstall-owned resource (issue #145).
# This suite is offline: destructive modes run only from copied checkouts with a stub Docker CLI.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

UNIX=uninstall.sh
WINDOWS=uninstall-windows.ps1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

unix_offenders() {
    grep -niE 'keep-dir|rm -rf.*REPO_DIR|cas-uninstall\.|Removing directory.*REPO_DIR|exec .*remover' "$1"
}
windows_offenders() {
    grep -niE 'KeepDir|cas-uninstall-|Remove-Item.*(RepoDir|Target).*Recurse|Start-Process.*remover|Removing directory.*RepoDir' "$1"
}

if unix_offenders "$UNIX" >/dev/null 2>&1; then
    unix_offenders "$UNIX" >&2
    fail 'the Unix uninstaller still has a keep-directory option or checkout-removal path'
fi
if windows_offenders "$WINDOWS" >/dev/null 2>&1; then
    windows_offenders "$WINDOWS" >&2
    fail 'the Windows uninstaller still has a keep-directory option or checkout-removal path'
fi
grep -q 'Directory:.*kept' "$UNIX" || fail 'the Unix preview does not say the checkout is kept'
grep -q 'Directory:.*kept' "$WINDOWS" || fail 'the Windows preview does not say the checkout is kept'
ok 'both uninstallers preserve the checkout unconditionally and say so in their preview'

for file in README.md docs/wsl-warp.md uninstall.cmd; do
    if grep -qiE -- 'keep-dir|KeepDir|repo( directory| dir).*remove|remove.*repo( directory| dir)' "$file"; then
        fail "$file still presents checkout deletion or a keep-directory option"
    fi
done
grep -qi 'preserv.*repository checkout' uninstall.cmd \
    || fail 'the Windows wrapper does not state the checkout-preservation boundary'
ok 'maintained operator documentation has no keep-directory option or checkout-removal claim'

# Prove both detectors can fail. These mutants are never executed.
cp "$UNIX" "$TMP/unix-mutant"
printf '\nrm -rf "$REPO_DIR"\n' >>"$TMP/unix-mutant"
unix_offenders "$TMP/unix-mutant" >/dev/null 2>&1 \
    || fail 'the Unix detector missed a reintroduced recursive checkout deletion'
cp "$WINDOWS" "$TMP/windows-mutant"
printf '\nRemove-Item -LiteralPath $RepoDir -Recurse -Force\n' >>"$TMP/windows-mutant"
windows_offenders "$TMP/windows-mutant" >/dev/null 2>&1 \
    || fail 'the Windows detector missed a reintroduced recursive checkout deletion'
ok 'the static boundary detects deliberate Unix and Windows deletion regressions'

STUB="$TMP/bin"
mkdir -p "$STUB"
cat >"$STUB/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_TRACE"
case "${1:-} ${2:-}" in
    'info '|'compose down'|'rm -f'|'volume rm'|'network rm'|'image rm'|'image prune') exit 0 ;;
    'image inspect') exit 1 ;;
    'ps -aq'|'volume ls'|'network ls') exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$STUB/docker"

run_mode() { # run_mode LABEL [uninstall args...]
    local label="$1" repo home output
    shift
    repo="$TMP/repo-$label"
    home="$TMP/home-$label"
    mkdir -p "$repo" "$home"
    cp "$UNIX" "$repo/uninstall.sh"
    chmod +x "$repo/uninstall.sh"
    printf 'operator-owned checkout marker\n' >"$repo/.checkout-must-survive"
    : >"$TMP/docker-$label.trace"
    output=$(cd "$repo" && HOME="$home" PATH="$STUB:/usr/bin:/bin" \
        DOCKER_TRACE="$TMP/docker-$label.trace" ./uninstall.sh -y "$@" 2>&1) \
        || fail "$label mode exited non-zero: $output"
    [ -f "$repo/.checkout-must-survive" ] \
        || fail "$label mode deleted the checkout or its marker"
    grep -q 'Directory:.*kept' <<<"$output" \
        || fail "$label mode did not disclose checkout preservation"
}

run_mode default
grep -q '^compose down' "$TMP/docker-default.trace" \
    || fail 'the default preservation run stopped attempting Docker teardown'
run_mode skip-docker --skip-docker
run_mode keep-engine --keep-docker-engine
run_mode force-engine --remove-docker-engine
ok 'default, skip-Docker, keep-engine, and forced-engine modes preserve a copied checkout'

LEGACY_REPO="$TMP/repo-retired-option"
mkdir -p "$LEGACY_REPO"
cp "$UNIX" "$LEGACY_REPO/uninstall.sh"
chmod +x "$LEGACY_REPO/uninstall.sh"
printf 'operator-owned checkout marker\n' >"$LEGACY_REPO/.checkout-must-survive"
set +e
legacy_output=$(cd "$LEGACY_REPO" && HOME="$TMP/home-retired" PATH="$STUB:/usr/bin:/bin" \
    DOCKER_TRACE="$TMP/docker-retired.trace" ./uninstall.sh -y --keep-dir 2>&1)
legacy_status=$?
set -e
[ "$legacy_status" -eq 2 ] || fail "the retired --keep-dir option returned $legacy_status instead of 2"
grep -q 'Unknown option: --keep-dir' <<<"$legacy_output" \
    || fail 'the retired --keep-dir option did not fail as unknown'
[ -f "$LEGACY_REPO/.checkout-must-survive" ] \
    || fail 'rejecting the retired option modified the checkout'
ok 'the retired Unix keep-directory option is rejected before any teardown'

printf '\nAll %d checkout-preservation checks passed.\n' "$PASSED"
