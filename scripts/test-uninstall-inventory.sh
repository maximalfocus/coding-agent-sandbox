#!/usr/bin/env bash
# The uninstallers' inventory must stay complete (issue #125).
#
# Both removal lists are hand-maintained and were written before SL-09, SL-12, SL-14 and the AWS
# slice added their volumes. Nothing tied them to the compose files, so each new volume silently
# widened the gap: an uninstall left `coding-agent-sandbox-secret` (a real Claude access AND refresh
# token), `-deepseek-secret` (an API key) and `-mitm-ca` (the intercept CA's private key) on the host
# while reporting that it had removed everything the sandbox created.
#
# This compares what the compose files DECLARE against what each uninstaller REMOVES, so a volume
# added by a future slice cannot be forgotten in either half.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

# --- what the compose files declare -----------------------------------------
# Both forms: "${VAR:-default}" and a bare literal.
declared_names() {  # $1 = yaml key to harvest (name | container_name)
    local key="$1" f
    for f in $(git ls-files 'docker-compose*.yml'); do
        if [ "$key" = name ]; then
            awk '/^volumes:/{v=1} v && /name:/{print}' "$f"
        else
            grep -E "^\s+container_name:" "$f"
        fi
    done | sed -E 's/^[[:space:]]*[a-z_]+:[[:space:]]*//; s/^"//; s/"$//' \
         | sed -E 's/^\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}$/\1/' \
         | grep -E '^[a-z0-9][a-z0-9._-]*$' | sort -u
}

# --- what each uninstaller removes ------------------------------------------
sh_block()  { sed -n "/^$1=(/,/^)/p" uninstall.sh | sed -E 's/.*\(pick [^)]*[[:space:]]([a-z0-9][a-z0-9._-]*)\).*/\1/' \
                | grep -E '^[a-z0-9][a-z0-9._-]*$' | sort -u; }
ps_block()  { sed -n "/^\\\$$1 *= *@(/,/^)/p" uninstall-windows.ps1 \
                | grep -oE "'[a-z0-9][a-z0-9._-]*'\)?,?\s*$" | tr -d "'),␠" | sed 's/[[:space:]]*$//' \
                | grep -E '^[a-z0-9][a-z0-9._-]*$' | sort -u; }

dv=$(declared_names name)
dc=$(declared_names container_name)
[ "$(wc -l <<<"$dv")" -ge 10 ] || fail "only $(wc -l <<<"$dv") volumes were parsed from the compose files — the scan has stopped matching"
[ "$(wc -l <<<"$dc")" -ge 3 ]  || fail "only $(wc -l <<<"$dc") container names were parsed — the scan has stopped matching"
ok "$(wc -l <<<"$dv" | tr -d ' ') volumes and $(wc -l <<<"$dc" | tr -d ' ') container names parsed from the compose files"

# Volumes deliberately NOT removed would be listed here with a reason. There are none.
RETAINED=""

for half in sh ps; do
    case "$half" in
        sh) rv=$(sh_block VOLUMES); rc=$(sh_block CONTAINERS); label=uninstall.sh ;;
        ps) rv=$(ps_block Volumes); rc=$(ps_block Containers); label=uninstall-windows.ps1 ;;
    esac
    [ -n "$rv" ] || fail "$label: no volumes were parsed from its removal list"
    missing=$(comm -23 <(printf '%s\n' "$dv") <(printf '%s\n' "$rv" | sort -u))
    [ -n "$RETAINED" ] && missing=$(grep -vxF "$RETAINED" <<<"$missing")
    [ -z "$missing" ] || fail "$label never removes these declared volumes:
$(sed 's/^/    /' <<<"$missing")"
    ok "$label removes every volume the compose files declare"

    missing_c=$(comm -23 <(printf '%s\n' "$dc") <(printf '%s\n' "$rc" | sort -u))
    [ -z "$missing_c" ] || fail "$label never removes these declared containers:
$(sed 's/^/    /' <<<"$missing_c")"
    ok "$label removes every container the compose files declare"
done

# --- the credential volumes by name, because they are the reason this exists -
for v in coding-agent-sandbox-secret coding-agent-sandbox-deepseek-secret coding-agent-sandbox-mitm-ca; do
    grep -q "$v" uninstall.sh          || fail "uninstall.sh does not remove $v"
    grep -q "$v" uninstall-windows.ps1 || fail "uninstall-windows.ps1 does not remove $v"
done
ok "the token vault, the DeepSeek key and the intercept CA are removed by both halves"

# --- the check must be able to fail -----------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp -R "$ROOT" "$TMP/r"

# 1. a compose file gains a volume nobody removes
cat >> "$TMP/r/docker-compose.yml" <<'YEOF'

volumes:
  invented-by-the-test:
    name: "${INVENTED_VOLUME_NAME:-coding-agent-sandbox-invented}"
YEOF
out=$( cd "$TMP/r" && bash scripts/test-uninstall-inventory.sh 2>&1 )
grep -q 'coding-agent-sandbox-invented' <<<"$out" \
    || fail "a newly declared volume that nothing removes was NOT detected: $out"
ok "a volume added to a compose file but not to the removal lists IS detected"

# 2. a removal list loses an entry
cp -R "$ROOT" "$TMP/r2"
sed -i.bak '/coding-agent-sandbox-deepseek-secret/d' "$TMP/r2/uninstall.sh"
out=$( cd "$TMP/r2" && bash scripts/test-uninstall-inventory.sh 2>&1 )
grep -q 'coding-agent-sandbox-deepseek-secret' <<<"$out" \
    || fail "a removal-list entry deleted from uninstall.sh was NOT detected: $out"
ok "an entry removed from a removal list IS detected"

printf '\nAll %d checks passed.\n' "$PASSED"
