#!/usr/bin/env bash
# Build + start the Claude Code sandbox, then print where to open it.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
    echo "No .env found. Run:  cp .env.example .env  then edit WORKSPACE_DIR + the password."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "Docker isn't running. Start Docker Desktop (or OrbStack) and try again."
    exit 1
fi

# Guard every mounted host dir: refuse broad/sensitive dirs so a typo in .env can't expose your
# whole home or credentials to the sandbox (the compose mounts have no guard themselves).
# Canonicalize $HOME so the comparison holds even when home is reached via a symlink.
home_abs="$(cd "$HOME" 2>/dev/null && pwd -P)"; home_abs="${home_abs:-$HOME}"

# read_env KEY -> the (single) non-comment value from .env, quotes stripped; empty if unset.
read_env() {
    local key="$1" lines v
    lines="$(grep -E "^[[:space:]]*${key}=" .env | grep -vE '^[[:space:]]*#' || true)"
    if [ "$(printf '%s\n' "$lines" | grep -c .)" -gt 1 ]; then
        echo "Multiple ${key} entries in .env — ambiguous; keep exactly one." >&2; exit 1
    fi
    v="$(printf '%s' "$lines" | head -1 | cut -d= -f2-)"
    printf '%s' "$v" | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# A configured SSO region is the explicit opt-in for sandbox-private AWS state as well as egress.
# Keep the base stack unchanged otherwise; naming both files is required once -f is used.
compose_cmd=(docker compose)
aws_sso_regions="$(read_env AWS_SSO_REGIONS)"
if [ -n "$aws_sso_regions" ]; then
    compose_cmd+=( -f docker-compose.yml -f docker-compose.aws.yml )
    echo "  AWS SSO enabled -> isolated coding-agent-sandbox-aws volume"
fi

# validate_mount RAW LABEL -> echo canonical abs path, or print reason to stderr and exit 1.
validate_mount() {
    local raw="$1" label="$2" abs bad
    abs="$(cd "$raw" 2>/dev/null && pwd -P)" || { echo "${label} '$raw' does not exist." >&2; exit 1; }
    if [ "$abs" = "$home_abs" ] || [ "$abs" = "/" ]; then
        echo "Refusing to mount '$abs' (your whole home or filesystem root) for ${label}." >&2; exit 1
    fi
    for bad in "$home_abs/.ssh" "$home_abs/.aws" "$home_abs/.gnupg" "$home_abs/.config" \
               "$home_abs/.kube" "$home_abs/.docker" "$home_abs/.gcloud" "$home_abs/.azure"; do
        if [ "$abs" = "$bad" ] || case "$abs" in "$bad"/*) true;; *) false;; esac; then
            echo "Refusing to mount sensitive path '$abs' for ${label}." >&2; exit 1
        fi
    done
    case "$home_abs" in "$abs"/*) echo "Refusing: ${label} '$abs' contains your home dir." >&2; exit 1;; esac
    printf '%s' "$abs"
}

# Enforced mapping: WORK_DIR -> /workspace/work, PERSONAL_DIR -> /workspace/personal (both below).
# WORKSPACE_DIR (the /workspace ROOT) is OPTIONAL: leave it blank to get an inert umbrella volume
# that just holds those two mount points. Only when it's set do we validate + export it (so Compose
# mounts exactly the host dir we checked); blank -> Compose falls back to the claude-workspace volume.
wd="$(read_env WORKSPACE_DIR)"
if [ -n "$wd" ]; then
    WORKSPACE_DIR="$(validate_mount "$wd" WORKSPACE_DIR)" || exit 1; export WORKSPACE_DIR
else
    echo "  /workspace -> inert umbrella volume (work + personal mount inside; set WORKSPACE_DIR for a real root)"
fi

# read_compat NEW OLD -> value of NEW, else OLD (with a one-time deprecation notice), else empty.
read_compat() {
    local v; v="$(read_env "$1")" || exit 1
    if [ -z "$v" ]; then
        v="$(read_env "$2")" || exit 1
        [ -n "$v" ] && echo "  (note: $2 is deprecated — rename it to $1 in .env)" >&2
    fi
    printf '%s' "$v"
}
ps="$(read_compat PERSONAL_DIR WS_DIR)" || exit 1
if [ -n "$ps" ]; then PERSONAL_DIR="$(validate_mount "$ps" PERSONAL_DIR)" || exit 1; export PERSONAL_DIR
    echo "  mounting PERSONAL_DIR  -> /workspace/personal  ($PERSONAL_DIR)"; fi
wk="$(read_compat WORK_DIR PROJECTS_DIR)" || exit 1
if [ -n "$wk" ]; then WORK_DIR="$(validate_mount "$wk" WORK_DIR)" || exit 1; export WORK_DIR
    echo "  mounting WORK_DIR      -> /workspace/work  ($WORK_DIR)"; fi

# Behind a TLS-inspecting proxy (Cloudflare WARP / Zscaler)? Any PEM in certs/ is trusted at build
# + runtime (see certs/README.md). Advisory only — an empty certs/ is a no-op.
# NB: `ls certs/*.crt` would exit non-zero on no match, and under `set -o pipefail` that
# non-zero status propagates to this assignment and `set -e` kills the script. `find` returns 0
# even with zero matches, so an empty certs/ is genuinely a no-op (as intended).
ncerts=$(find certs -maxdepth 1 -type f \( -name '*.crt' -o -name '*.pem' \) 2>/dev/null | wc -l | tr -d ' ')
[ "${ncerts:-0}" -gt 0 ] && echo "  trusting ${ncerts} custom CA cert(s) from certs/ (corporate / TLS-inspecting proxy)"

# Build, then run a supply-chain scan. The scan is ADVISORY by default (prints findings, doesn't
# block — see scan.sh); set TRIVY_STRICT=1 to make it gate the start, or SKIP_TRIVY=1 to skip it.
echo "Building image..."
"${compose_cmd[@]}" build
if [ -n "${SKIP_TRIVY:-}" ]; then
    echo "  (SKIP_TRIVY set — skipping image vulnerability scan)"
elif ! TRIVY_SUMMARY=1 ./scan.sh; then
    echo
    if [ -n "${TRIVY_STRICT:-}" ]; then
        # STRICT mode: scan.sh exits non-zero on findings AND on operational errors — gate the start.
        echo "STRICT scan failed (see above). Set SKIP_TRIVY=1 to start anyway, or reduce the"
        echo "surface by bumping the base-image digest in the Dockerfile and rebuilding."
        exit 1
    else
        # Advisory mode: findings never set a non-zero code (scan.sh runs with --exit-code 0), so a
        # failure here is OPERATIONAL (no Trivy, Docker Hub pull/rate-limit/TLS/offline). Don't let
        # that block a first-run setup — warn and continue.
        echo "  (advisory scan could not complete — continuing anyway; set SKIP_TRIVY=1 to skip it)"
    fi
fi
"${compose_cmd[@]}" up -d

# `|| true`: a missing TTYD_PORT must not trip `set -o pipefail`/`set -e` after a successful `up -d`.
port="$(grep -E '^TTYD_PORT=' .env | cut -d= -f2 || true)"; port="${port:-7681}"
cat <<EOF

  Claude Code sandbox is running.

  1. Open:  http://127.0.0.1:${port}
  2. Log in with the TTYD_USER / TTYD_PASS from your .env
  3. In the terminal:  claude   ->   /login   ->  paste the code from your browser
     (login persists across restarts)

  Local Herdr:     ./shell.sh             Plain Bash escape hatch:     ./shell.sh --shell
  Stop with:   docker compose down       Logs:  docker compose logs -f
EOF
