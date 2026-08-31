#!/usr/bin/env bash
# Update the pinned agent-CLI versions FROM THE HOST.
#
#   ./scripts/update-agent-clis.sh                    # report only — changes nothing
#   ./scripts/update-agent-clis.sh --apply            # move every pin to the published version
#   ./scripts/update-agent-clis.sh --apply claude     # ...only the ones you name
#   ./scripts/update-agent-clis.sh --apply codex=0.150.0
#
# Why the host: the CLIs are pinned at build time and their runtime self-update is disabled, so the
# running CLI cannot drift mid-session. Updating from inside the sandbox would mean turning on
# ALLOW_TOOL_UPGRADES and letting the container fetch its own tooling — trading a reviewable
# build-time pin for unreviewed runtime drift. The registry lookup therefore happens here, over the
# host's own network, and the sandbox's egress grants are left exactly as they are.
#
# This is not an auto-updater. It writes nothing without --apply, and it never rebuilds: run
# ./run.sh yourself once you have reviewed the diff.
#
# Deliberately limited to the four npm-published agent CLIs. Herdr and ttyd are pinned by release
# AND per-architecture sha256; moving those means re-deriving checksums, which is a hand edit.
set -euo pipefail
cd "$(dirname "$0")/.."

DOCKERFILE=Dockerfile

# Parallel lists, not an associative array: macOS ships bash 3.2, which has neither.
KEYS="claude codex opencode pi"
key_arg() {
    case "$1" in
        claude)   echo CLAUDE_CODE_VERSION ;;
        codex)    echo CODEX_VERSION ;;
        opencode) echo OPENCODE_VERSION ;;
        pi)       echo PI_VERSION ;;
    esac
}
key_pkg() {
    case "$1" in
        claude)   echo "@anthropic-ai/claude-code" ;;
        codex)    echo "@openai/codex" ;;
        opencode) echo "opencode-ai" ;;
        pi)       echo "@earendil-works/pi-coding-agent" ;;
    esac
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
usage: update-agent-clis.sh [--apply] [--dockerfile PATH] [NAME|NAME=VERSION ...]

  NAME is one of: claude, codex, opencode, pi. With none given, all four are considered.
  With no --apply the Dockerfile is left byte-identical.

  NAME=VERSION pins an exact version instead of the published one. It is checked against the
  registry first; a version that does not exist there is refused rather than written.
USAGE
}

command -v curl    >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (to read the registry's JSON)"

# --- arguments ------------------------------------------------------------------------------------
APPLY=
SELECTED=
PINS=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply)      APPLY=1 ;;
        --dockerfile) shift; [ "$#" -gt 0 ] || die "--dockerfile needs a path"; DOCKERFILE="$1" ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "unknown option '$1' (see --help)" ;;
        *)
            name="${1%%=*}"
            case " $KEYS " in *" $name "*) ;; *) die "unknown CLI '$name' (see --help)" ;; esac
            case " $SELECTED " in *" $name "*) die "'$name' named twice" ;; esac
            SELECTED="$SELECTED $name"
            case "$1" in *=*) PINS="$PINS $1" ;; esac
            ;;
    esac
    shift
done
[ -n "$SELECTED" ] || SELECTED="$KEYS"
[ -f "$DOCKERFILE" ] || die "no such file: $DOCKERFILE"

# pinned_version ARG -> the version currently in the Dockerfile
pinned_version() {
    sed -n "s/^ARG $1=\\(.*\\)\$/\\1/p" "$DOCKERFILE" | head -1
}

# published_version PKG -> the registry's current "latest"; empty output means the lookup failed,
# which is reported as a refusal rather than quietly read as "already up to date".
published_version() {
    curl -fsS -m 30 "https://registry.npmjs.org/$1/latest" 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["version"])' 2>/dev/null || true
}

# version_exists PKG VERSION -> 0 when the registry serves exactly that version
version_exists() {
    curl -fsS -m 30 "https://registry.npmjs.org/$1/$2" >/dev/null 2>&1
}

# explicit_pin NAME -> the version requested for it on the command line, else empty
explicit_pin() {
    for entry in $PINS; do
        [ "${entry%%=*}" = "$1" ] && { printf '%s' "${entry#*=}"; return; }
    done
}

# --- resolve --------------------------------------------------------------------------------------
printf '%-10s %-32s %-12s %-12s %s\n' CLI PACKAGE PINNED TARGET ''
changes=
failures=
for name in $SELECTED; do
    arg="$(key_arg "$name")"; pkg="$(key_pkg "$name")"
    current="$(pinned_version "$arg")"
    [ -n "$current" ] || die "$arg is not pinned in $DOCKERFILE — refusing to guess"

    wanted="$(explicit_pin "$name")"
    if [ -n "$wanted" ]; then
        if version_exists "$pkg" "$wanted"; then note="requested"
        else
            printf '%-10s %-32s %-12s %-12s %s\n' "$name" "$pkg" "$current" "$wanted" "NOT IN REGISTRY"
            failures="$failures $name"; continue
        fi
    else
        wanted="$(published_version "$pkg")"
        if [ -z "$wanted" ]; then
            printf '%-10s %-32s %-12s %-12s %s\n' "$name" "$pkg" "$current" "?" "LOOKUP FAILED"
            failures="$failures $name"; continue
        fi
        note="published"
    fi

    if [ "$current" = "$wanted" ]; then
        printf '%-10s %-32s %-12s %-12s %s\n' "$name" "$pkg" "$current" "$wanted" "up to date"
    else
        printf '%-10s %-32s %-12s %-12s %s\n' "$name" "$pkg" "$current" "$wanted" "-> $note"
        changes="$changes $arg=$wanted"
    fi
done

# A lookup we could not complete is not evidence that a pin is current. Fail closed.
if [ -n "$failures" ]; then
    echo >&2
    die "could not resolve:$failures — nothing was written"
fi

if [ -z "$changes" ]; then
    echo; echo "Every selected pin is already current. Nothing to do."
    exit 0
fi

if [ -z "$APPLY" ]; then
    echo
    echo "Report only — $DOCKERFILE is unchanged. Re-run with --apply to move these pins."
    exit 0
fi

# --- apply ----------------------------------------------------------------------------------------
# Rewrite only the exact `ARG NAME=` lines resolved above. Every other pin in the file — the base
# image digest, ttyd, npm, Herdr, Bun, Playwright, the AWS CLI and the Docker clients — is left
# alone, as are ALLOW_TOOL_UPGRADES and the disabled runtime self-updater.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp "$DOCKERFILE" "$tmp"
for change in $changes; do
    arg="${change%%=*}"; version="${change#*=}"
    python3 - "$tmp" "$arg" "$version" <<'PY'
import re, sys
path, arg, version = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as handle:
    text = handle.read()
pattern = re.compile(r"^ARG %s=.*$" % re.escape(arg), re.MULTILINE)
if len(pattern.findall(text)) != 1:
    raise SystemExit("refusing to edit %s: expected exactly one 'ARG %s=' line" % (path, arg))
with open(path, "w") as handle:
    handle.write(pattern.sub("ARG %s=%s" % (arg, version), text))
PY
done
mv "$tmp" "$DOCKERFILE"
trap - EXIT

echo
echo "Updated $DOCKERFILE:"
for change in $changes; do echo "  ARG ${change%%=*}=${change#*=}"; done
cat <<'NEXT'

Review the diff, then rebuild — the rebuild is deliberately a separate step:

  git diff Dockerfile
  ./run.sh
NEXT
