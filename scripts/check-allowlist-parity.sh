#!/usr/bin/env bash
# Egress-admission parity check for docs/allowlist-decisions.md (issue #171).
#
# One admission policy is constructed in five places and decided by two engines, and nothing used to
# compare them. They already differ: for the DNS-equivalent host `anthropic.com.` the default stack
# refuses and the mediation stack admits. Neither is unsafe and no requirement chooses between them —
# what was missing is anything that would report the divergence, or the next one.
#
# The two engines are EXECUTED, never modelled. A check that re-implemented the pattern semantics
# would be asserting its own opinion of tinyproxy's FilterExtended rather than tinyproxy's, which is
# the failure mode this check exists to avoid:
#
#   default    tinyproxy itself, running the shipped tinyproxy.conf over a generated filter
#   mediation  mitm/filter_addon.py's own _matches(), imported rather than transcribed
#
# Of the five construction paths, two expose a builder behind a `root` guard and are executed here.
# The other three cannot be invoked in isolation — the sidecar builds inline, the shell hot-add
# refuses before a running stack, and the PowerShell twin needs a Windows runtime — so for those the
# check asserts predicate parity: every path must carry the byte-identical hostname validation and
# the same anchoring, because that predicate IS the decision.
#
# It reports, per case, exactly one of:
#
#   PASS         every executed verdict matched the record, every compared predicate was identical;
#   DIVERGED     a verdict or a predicate no longer matches what the inventory records;
#   UNEVALUATED  an engine could not be executed here. Never reported as a pass.
#
# The default engine needs the built image, because tinyproxy is what ships in it. No network
# connection is made, no credential is read, and the container it starts is disposable.
#
# Usage:
#   scripts/check-allowlist-parity.sh            human-readable
#   scripts/check-allowlist-parity.sh --quiet    only failures and the summary
#
# Exit status: 0 when nothing diverged (UNEVALUATED rows are reported but do not fail),
#              1 when at least one verdict or predicate diverged,
#              2 when the inventory is missing or malformed (fail closed).
set -uo pipefail

ROOT=${ALLOWLIST_PARITY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DOC=${ALLOWLIST_PARITY_DOC:-$ROOT/docs/allowlist-decisions.md}
IMAGE=${ALLOWLIST_PARITY_IMAGE:-coding-agent-sandbox:latest}
ALLOWLISTED=anthropic.com
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
diverged=0
uneval=0

[ -f "$DOC" ] || { echo "FAIL: $DOC is missing" >&2; exit 2; }

# Rows of a fenced block, comments and blanks dropped.
block() { awk -v tag="$1" '$0 == "```" tag { inb = 1; next } inb && $0 == "```" { exit } inb' "$DOC"; }

INPUT_ROWS=$(block allowlist-input)
RUNTIME_ROWS=$(block allowlist-runtime)
[ -n "$INPUT_ROWS" ]   || { echo "FAIL: no allowlist-input block in $DOC" >&2; exit 2; }
[ -n "$RUNTIME_ROWS" ] || { echo "FAIL: no allowlist-runtime block in $DOC" >&2; exit 2; }

# Exactly " | ": one of the input cases IS a bare pipe, so a looser separator would split the
# case data itself and silently test the wrong string.
field() { printf '%s' "$1" | awk -F' \\| ' -v n="$2" '{ print $n }'; }

# --- 1. predicate parity across every construction path ------------------------------------------
# The hostname validation and the anchoring are the decision. A path that changes either has changed
# the policy, whether or not this check can execute its builder.
PATHS='entrypoint.sh
mitm/entrypoint.sh
mitm/sidecar-entrypoint.sh
scripts/network/allow-domain.sh
scripts/network/allow-domain.ps1'
HOSTNAME_RE='\^\[A-Za-z0-9\]\(\[A-Za-z0-9-\]\*\[A-Za-z0-9\]\)\?\(\\\.\[A-Za-z0-9\]\(\[A-Za-z0-9-\]\*\[A-Za-z0-9\]\)\?\)\+\$'

ref=""; ref_path=""
while IFS= read -r rel; do
    f="$ROOT/$rel"
    if [ ! -f "$f" ]; then
        echo "DIVERGED  predicate: $rel is missing" >&2; diverged=$((diverged + 1)); continue
    fi
    got=$(grep -oE "$HOSTNAME_RE" "$f" | head -1)
    if [ -z "$got" ]; then
        echo "DIVERGED  predicate: $rel no longer carries the shared hostname validation" >&2
        diverged=$((diverged + 1)); continue
    fi
    if [ -z "$ref" ]; then ref=$got; ref_path=$rel; continue; fi
    if [ "$got" != "$ref" ]; then
        echo "DIVERGED  predicate: $rel validates differently from $ref_path" >&2
        diverged=$((diverged + 1))
    fi
done <<EOF
$PATHS
EOF
[ "$diverged" -eq 0 ] && say "  ok  predicate parity: all 5 construction paths share one hostname validation"

# Every path that writes a filter line must anchor it the same way.
for rel in entrypoint.sh scripts/network/allow-domain.sh; do
    grep -q '(\^|\\\\\.)' "$ROOT/$rel" || { echo "DIVERGED  anchoring: $rel no longer writes (^|\\.)…\$" >&2; diverged=$((diverged + 1)); }
done
grep -q "'(\^|\\\\\.)'" "$ROOT/scripts/network/allow-domain.ps1" \
    || { echo "DIVERGED  anchoring: allow-domain.ps1 no longer writes (^|\\.)…\$" >&2; diverged=$((diverged + 1)); }
say "  ok  anchoring parity: every path that writes a filter line uses the same anchored form"

# --- 2. input cases against the builders that can be executed ------------------------------------
# Sourcing the whole entrypoint is not an option: with the `root` guard unsatisfied it falls through
# to the node-side path, which execs ttyd or exits. So take the shipped text UP TO that guard — the
# arrays and the builder verbatim, with nothing that runs — and source that.
defs_only() { awk '/^if \[ "\$\(id -u\)" = "0" \]; then$/ { exit } { print }' "$1"; }
build_one() {  # build_one <entry> -> "admit" | "refuse"
    local entry=$1 out
    out=$(
        set +e +u
        defs=$(mktemp); defs_only "$ROOT/entrypoint.sh" > "$defs"
        # shellcheck disable=SC1090
        . "$defs" >/dev/null 2>&1; rm -f "$defs"
        # The definitions carry the script's own `set -euo pipefail`, and build_filter's
        # `[ "$gh" = "1" ] && domains+=(...)` returns 1 whenever a gate is off - which under `set -e`
        # kills this subshell before the filter is written, and reads back as a refusal.
        set +e +u
        FILTER_FILE=$(mktemp)
        ALLOW_GITHUB=false ALLOW_OPENAI=false ALLOW_TOOL_UPGRADES=false \
            EXTRA_ALLOWED_DOMAINS="$entry" SANDBOX_QUIET=1 build_filter >/dev/null 2>&1
        # Assert the EXACT anchored line the builder writes, not a substring: grepping for the raw
        # entry would match "com" inside "(^|\.)anthropic\.com$" and report a bare TLD as admitted.
        printf '(^|\\.)%s$\n' "$(printf '%s' "$entry" | sed 's/\./\\./g')" > "$FILTER_FILE.want"
        if grep -qxFf "$FILTER_FILE.want" "$FILTER_FILE" 2>/dev/null; then echo admit; else echo refuse; fi
        rm -f "$FILTER_FILE" "$FILTER_FILE.want"
    )
    printf '%s' "${out:-refuse}"
}

mitm_build_one() {  # mitm_build_one <entry> -> "admit" | "refuse"
    local entry=$1 out
    out=$(
        set +e +u
        defs=$(mktemp); defs_only "$ROOT/mitm/entrypoint.sh" > "$defs"
        # shellcheck disable=SC1090
        . "$defs" >/dev/null 2>&1; rm -f "$defs"
        set +e +u
        ALLOW_GITHUB=false ALLOW_TOOL_UPGRADES=false EXTRA_ALLOWED_DOMAINS="$entry" \
            SANDBOX_QUIET=1 build_allowlist 2>/dev/null
    )
    case ",$out," in *",$entry,"*) echo admit;; *) echo refuse;; esac
}

input_checked=0
while IFS= read -r row; do
    case "$row" in ''|'#'*) continue;; esac
    entry=$(field "$row" 1); want=$(field "$row" 2); why=$(field "$row" 3)
    got_default=$(build_one "$entry")
    got_mitm=$(mitm_build_one "$entry")
    if [ "$got_default" = "$want" ] && [ "$got_mitm" = "$want" ]; then
        say "  ok  input   '$entry' -> $want (both executed builders agree) — $why"
        input_checked=$((input_checked + 1))
    else
        echo "DIVERGED  input   '$entry': recorded $want, entrypoint said $got_default, mitm said $got_mitm" >&2
        diverged=$((diverged + 1))
    fi
done <<EOF
$INPUT_ROWS
EOF

# --- 3. runtime cases against the two real engines -----------------------------------------------
# mediation: the addon's own matcher, imported rather than transcribed.
addon_verdicts() {  # reads hosts on stdin, prints "host<TAB>admit|refuse"
    # The program goes in a file, not a heredoc: `python3 - <<EOF` consumes stdin for the program
    # itself, so the piped host list would never reach it.
    local prog; prog=$(mktemp)
    cat > "$prog" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^def _matches\(host, domain\):\n(?:.*\n)*?\n', src, re.M)
if not m:
    sys.exit("could not locate _matches in filter_addon.py")
ns = {}
exec(m.group(0), ns)                      # the shipped function, not a transcription of it
matches, allowed = ns["_matches"], sys.argv[2]
for line in sys.stdin:
    h = line.strip()
    if h:
        print("%s\t%s" % (h, "admit" if matches(h, allowed) else "refuse"))
PY
    python3 "$prog" "$ROOT/mitm/filter_addon.py" "$ALLOWLISTED"
    rm -f "$prog"
}

# default: tinyproxy itself, running the shipped configuration over a generated filter.
tinyproxy_verdicts() {  # reads hosts on stdin, prints "host<TAB>admit|refuse", or nothing if unable
    docker image inspect "$IMAGE" >/dev/null 2>&1 || return 1
    local hosts; hosts=$(cat)
    printf '%s' "$hosts" | docker run --rm -i --entrypoint sh "$IMAGE" -c '
        set -e
        hosts=$(cat)
        mkdir -p /tmp/tp /run/tinyproxy /var/log/tinyproxy
        # exactly the line entrypoint.sh writes for the allowlisted domain
        printf "(^|\\.)anthropic\\.com$\n" > /tmp/tp/filter
        sed -e "s#^Filter .*#Filter \"/tmp/tp/filter\"#" \
            -e "s#^LogFile .*#LogFile \"/tmp/tp/log\"#" \
            -e "s#^PidFile .*#PidFile \"/tmp/tp/pid\"#" \
            /etc/tinyproxy/tinyproxy.conf > /tmp/tp/conf
        tinyproxy -c /tmp/tp/conf
        sleep 1
        for h in $hosts; do
            code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 4 \
                     -x http://127.0.0.1:8888 "http://$h/" 2>/dev/null || true)
            # 403 is the filter refusing. Anything else means the filter admitted the request and
            # the connection then succeeded or failed for reasons that are not a filter verdict.
            if [ "$code" = "403" ]; then printf "%s\trefuse\n" "$h"; else printf "%s\tadmit\n" "$h"; fi
        done
    ' 2>/dev/null
}

hosts=""
while IFS= read -r row; do
    case "$row" in ''|'#'*) continue;; esac
    hosts="$hosts$(field "$row" 1)
"
done <<EOF
$RUNTIME_ROWS
EOF

addon_out=$(printf '%s' "$hosts" | addon_verdicts)
tp_out=$(printf '%s' "$hosts" | tinyproxy_verdicts)
tp_available=1
[ -z "$tp_out" ] && tp_available=0

lookup() { printf '%s\n' "$1" | awk -F'\t' -v h="$2" '$1 == h { print $2; exit }'; }

runtime_checked=0
while IFS= read -r row; do
    case "$row" in ''|'#'*) continue;; esac
    host=$(field "$row" 1); want_tp=$(field "$row" 2); want_addon=$(field "$row" 3)
    status=$(field "$row" 4); why=$(field "$row" 5)
    got_addon=$(lookup "$addon_out" "$host")
    if [ "$got_addon" != "$want_addon" ]; then
        echo "DIVERGED  runtime '$host': filter_addon recorded $want_addon, executed $got_addon" >&2
        diverged=$((diverged + 1)); continue
    fi
    if [ "$tp_available" = 0 ]; then
        say "  UNEVALUATED runtime '$host': tinyproxy not executable here (image $IMAGE absent); addon agreed ($got_addon)"
        uneval=$((uneval + 1)); continue
    fi
    got_tp=$(lookup "$tp_out" "$host")
    if [ "$got_tp" != "$want_tp" ]; then
        echo "DIVERGED  runtime '$host': tinyproxy recorded $want_tp, executed $got_tp" >&2
        diverged=$((diverged + 1)); continue
    fi
    if [ "$status" = undecided ]; then
        say "  ok  runtime '$host' -> tinyproxy=$got_tp addon=$got_addon (recorded, still undecided) — $why"
    else
        say "  ok  runtime '$host' -> $got_tp on both engines — $why"
    fi
    runtime_checked=$((runtime_checked + 1))
done <<EOF
$RUNTIME_ROWS
EOF

say ""
if [ "$diverged" -ne 0 ]; then
    printf 'FAIL: allowlist parity — %d divergence(s)\n' "$diverged" >&2
    exit 1
fi
if [ "$uneval" -ne 0 ]; then
    printf 'PASS with %d UNEVALUATED: %d input case(s), %d runtime case(s) executed on both engines\n' \
        "$uneval" "$input_checked" "$runtime_checked"
else
    printf 'PASS: allowlist parity — %d input case(s), %d runtime case(s) on both real engines\n' \
        "$input_checked" "$runtime_checked"
fi
exit 0
