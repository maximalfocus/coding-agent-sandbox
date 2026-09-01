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
# Two kinds of pin are handled. The four npm-published CLIs are version-only. Herdr is pinned by
# release AND per-architecture sha256, so moving it means downloading each artifact and deriving its
# checksum from the bytes received.
#
# Be clear about what a derived checksum is worth: it attests the bytes fetched AT THAT MOMENT, not
# upstream intent. It is trust-on-first-use. What it buys - and this is worth having - is that no
# later build can be served different bytes without failing. It is not an upstream attestation, and
# that is why adopting a pin stays a separate step you review. The script says so in its own output
# rather than leaving you to infer it.
#
# ttyd is the same shape and is deliberately not included: it is not an agent tool.
set -euo pipefail
cd "$(dirname "$0")/.."

DOCKERFILE=Dockerfile

# Parallel lists, not an associative array: macOS ships bash 3.2, which has neither.
KEYS="claude codex opencode pi herdr"
# Tools whose pin includes per-architecture checksums, so --apply must download the artifacts.
CHECKSUM_KEYS="herdr"
# The canonical Herdr repository. 'ogulcancelik/herdr' resolves here only through GitHub's rename
# redirect; naming the real owner removes a dependency on a redirect this project does not control.
HERDR_REPO="herdrdev/herdr"
key_arg() {
    case "$1" in
        claude)   echo CLAUDE_CODE_VERSION ;;
        codex)    echo CODEX_VERSION ;;
        opencode) echo OPENCODE_VERSION ;;
        pi)       echo PI_VERSION ;;
        herdr)    echo HERDR_VERSION ;;
    esac
}
key_pkg() {
    case "$1" in
        claude)   echo "@anthropic-ai/claude-code" ;;
        codex)    echo "@openai/codex" ;;
        opencode) echo "opencode-ai" ;;
        pi)       echo "@earendil-works/pi-coding-agent" ;;
        herdr)    echo "github:$HERDR_REPO" ;;
    esac
}

is_checksum_key() {
    case " $CHECKSUM_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
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

# published_version NAME -> the current published version; empty output means the lookup failed,
# which is reported as a refusal rather than quietly read as "already up to date".
published_version() {
    if [ "$1" = "herdr" ]; then
        # Resolve through the releases/latest redirect rather than the API: no token, and no
        # unauthenticated rate limit to trip over. The final URL ends in /tag/vX.Y.Z.
        _url="$(curl -fsSLI -m 30 -o /dev/null -w '%{url_effective}' \
                "https://github.com/$HERDR_REPO/releases/latest" 2>/dev/null || true)"
        case "$_url" in
            */tag/v*) printf '%s' "${_url##*/tag/v}" ;;
            */tag/*)  printf '%s' "${_url##*/tag/}" ;;
        esac
        return
    fi
    curl -fsS -m 30 "https://registry.npmjs.org/$(key_pkg "$1")/latest" 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["version"])' 2>/dev/null || true
}

# version_exists NAME VERSION -> 0 when that exact version is published
version_exists() {
    if [ "$1" = "herdr" ]; then
        curl -fsSI -m 30 -o /dev/null \
            "https://github.com/$HERDR_REPO/releases/tag/v$2" >/dev/null 2>&1
        return
    fi
    curl -fsS -m 30 "https://registry.npmjs.org/$(key_pkg "$1")/$2" >/dev/null 2>&1
}

# sha256_of FILE -> the file's sha256, on either a macOS or a Linux host
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else die "need shasum or sha256sum to derive a checksum"
    fi
}

# herdr_checksum VERSION ARCH -> sha256 DERIVED from the artifact actually downloaded.
# Never accepts a checksum from an argument: a pin you were handed proves nothing.
herdr_checksum() {
    _v="$1"; _arch="$2"
    _out="$(mktemp)"
    if ! curl -fsSL -m 300 \
            "https://github.com/$HERDR_REPO/releases/download/v${_v}/herdr-linux-${_arch}" \
            -o "$_out" 2>/dev/null; then
        rm -f "$_out"; die "could not download herdr ${_v} for ${_arch} - nothing was written"
    fi
    # A truncated transfer or an error page must not be hashed and recorded as a pin. The real
    # binaries are ~20MB; anything tiny is not one.
    _size="$(wc -c < "$_out" | tr -d ' ')"
    if [ "${_size:-0}" -lt 1000000 ]; then
        rm -f "$_out"; die "herdr ${_v} ${_arch} download was only ${_size} bytes - refusing to pin it"
    fi
    sha256_of "$_out"
    rm -f "$_out"
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
        if version_exists "$name" "$wanted"; then note="requested"
        else
            printf '%-10s %-32s %-12s %-12s %s\n' "$name" "$pkg" "$current" "$wanted" "NOT IN REGISTRY"
            failures="$failures $name"; continue
        fi
    else
        wanted="$(published_version "$name")"
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

# --- what does moving these pins cost? --------------------------------------------------------------
# A pin move is a rebuild AND a revalidation. docs/pin-acceptance.md records which verification rests
# on each component's runtime behaviour; an unmapped pin is refused here rather than moved silently,
# because the failure that motivated this is exactly a bump whose cost nobody was told about.
# Resolution goes through check-pin-acceptance.sh so the tool and the check cannot disagree.
PIN_CHECK="$(dirname "$0")/check-pin-acceptance.sh"
[ -x "$PIN_CHECK" ] || die "missing $PIN_CHECK — cannot resolve what these pins carry"

# Every ARG this run could write, including the checksums a herdr move brings with it.
writable_args=
for change in $changes; do
    writable_args="$writable_args ${change%%=*}"
    [ "${change%%=*}" = "HERDR_VERSION" ] && \
        writable_args="$writable_args HERDR_SHA256_AMD64 HERDR_SHA256_ARM64"
done

unmapped=
affected=
for arg in $writable_args; do
    if row="$("$PIN_CHECK" --arg "$arg" 2>/dev/null)"; then
        verification="$(printf '%s' "$row" | cut -f1)"
        rerun="$(printf '%s' "$row" | cut -f2)"
        note="$(printf '%s' "$row" | cut -f3)"
        affected="$affected$arg|$verification|$rerun|$note
"
    else
        unmapped="$unmapped $arg"
    fi
done

if [ -n "$unmapped" ]; then
    echo >&2
    echo "These pins have no row in docs/pin-acceptance.md:$unmapped" >&2
    echo "Record what verification rests on each before moving it. Nothing was written." >&2
    exit 1
fi

echo
echo "Moving these pins invalidates the verification below. Re-run it after the rebuild:"
printf '%s' "$affected" | while IFS='|' read -r arg verification rerun note; do
    [ -n "$arg" ] || continue
    echo "  $arg"
    # printf '%s\n' — without the trailing newline `read` returns non-zero on the final entry and
    # the loop body never runs for it, so a row's last check would go unreported.
    printf '%s\n' "$verification" | tr ',' '\n' | while IFS= read -r check; do
        [ -n "$check" ] || continue
        case "$check" in
            operator:*) echo "      $check   <- NO AUTOMATED RUN PRODUCES THIS" ;;
            host:*)     echo "      $check   <- needs another host class" ;;
            none)       echo "      (nothing rests on this pin: $note)" ;;
            *)          echo "      $check" ;;
        esac
    done
    [ "$note" = "-" ] || [ "$rerun" = "none" ] || echo "      note: $note"
done

if [ -z "$APPLY" ]; then
    echo
    echo "Report only — $DOCKERFILE is unchanged. Re-run with --apply to move these pins."
    exit 0
fi

# --- apply ----------------------------------------------------------------------------------------
# Rewrite only the exact `ARG NAME=` lines resolved above. Every other pin in the file — the base
# image digest, ttyd, npm, Herdr, Bun, Playwright, the AWS CLI and the Docker clients — is left
# alone, as are ALLOW_TOOL_UPGRADES and the disabled runtime self-updater.
# Derive checksums BEFORE touching anything. A version bumped with a stale checksum would fail
# every later build, so the download has to succeed first or nothing is written at all. This is also
# why the report never downloads: 40MB of binaries is not a side effect a read-only command should
# have, and only an --apply that actually moves herdr pays for it.
for change in $changes; do
    [ "${change%%=*}" = "HERDR_VERSION" ] || continue
    _hv="${change#*=}"
    echo
    echo "Downloading herdr ${_hv} to derive its checksums (both architectures, one release)..."
    _amd64="$(herdr_checksum "$_hv" x86_64)"
    _arm64="$(herdr_checksum "$_hv" aarch64)"
    changes="$changes HERDR_SHA256_AMD64=$_amd64 HERDR_SHA256_ARM64=$_arm64"
    echo "  x86_64  $_amd64"
    echo "  aarch64 $_arm64"
    cat <<'CAVEAT'

  These checksums were derived from the bytes just downloaded. They attest WHAT WAS FETCHED NOW,
  not upstream intent - there is no published signature to check them against. What the pin buys is
  that no later build can be served different bytes without failing. Review before you rebuild.
CAVEAT
done

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
