#!/usr/bin/env bash
# Hot-add domain(s) to the RUNNING sandbox's allowlist without restarting the container.
# Effect is immediate but TEMPORARY — for a permanent rule, also add it to
# EXTRA_ALLOWED_DOMAINS in .env (it's re-applied on every container (re)start).
#
#   ./allow-domain.sh pypi.org files.pythonhosted.org
set -euo pipefail
cd "$(dirname "$0")"

[ "$#" -ge 1 ] || { echo "usage: ./allow-domain.sh <domain> [domain ...]"; exit 1; }
if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi

added=0
for d in "$@"; do
    # Validate as a strict multi-label hostname BEFORE building a regex — otherwise input like
    # ".*", "foo|.*", a bare TLD ("com") or an IP literal would widen the allowlist to ~everything.
    if ! printf '%s' "$d" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
       || printf '%s' "$d" | grep -qE '^[0-9.]+$'; then
        echo "skip invalid domain: '$d' (need a multi-label hostname, not a TLD or IP)" >&2; continue
    fi
    # Same anchored pattern the entrypoint uses: matches the domain + its subdomains only.
    esc=$(printf '%s' "$d" | sed 's/\./\\./g')
    line="(^|\\.)${esc}\$"
    added=1
    printf '%s\n' "$line" | docker compose exec -T claude-sandbox bash -lc \
        'l=$(cat); grep -qxF "$l" /etc/tinyproxy/filter || printf "%s\n" "$l" >> /etc/tinyproxy/filter'
    echo "allowed: $d"
done

# Nothing valid? Don't bother reloading.
if [ "$added" -eq 0 ]; then
    echo "No valid domains supplied — nothing added." >&2; exit 1
fi

# Reload the proxy filter in place (no dropped sessions, no restart). Signal as the tinyproxy user
# (same-uid signal needs no CAP_KILL, so the container can drop that capability).
docker compose exec -T -u tinyproxy claude-sandbox pkill -HUP tinyproxy
sleep 1

# Safety re-check: the allowlist must STILL deny a known-bad host. If example.com became
# reachable, a bad entry widened the filter to allow-all — warn loudly.
code=$(docker compose exec -T claude-sandbox curl -s -o /dev/null -w '%{http_code}' \
         --connect-timeout 5 -x http://127.0.0.1:8888 http://example.com/ 2>/dev/null || true)
if [ "$code" = "403" ]; then
    echo "ok: allowlist still denies example.com (403)."
    echo "proxy reloaded. (Permanent? add these to EXTRA_ALLOWED_DOMAINS in .env)"
else
    echo "ERROR: example.com is no longer denied (got '${code:-none}') — the allowlist looks too" \
         "broad. Inspect: docker compose exec claude-sandbox cat /etc/tinyproxy/filter" >&2
    exit 1
fi
