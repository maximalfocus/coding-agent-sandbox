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

# WORKSPACE_DIR (required; the /workspace root). WS_DIR + PROJECTS_DIR (optional) mount at
# /workspace/ws and /workspace/projects so you can work across normal + enterprise projects in one
# session. Export the validated ABS paths so Compose mounts exactly what we checked (and so a
# relative/symlinked .env value can't slip past the guard).
wd="$(read_env WORKSPACE_DIR)"; wd="${wd:-./workspace}"
WORKSPACE_DIR="$(validate_mount "$wd" WORKSPACE_DIR)" || exit 1; export WORKSPACE_DIR
ws="$(read_env WS_DIR)" || exit 1
if [ -n "$ws" ]; then WS_DIR="$(validate_mount "$ws" WS_DIR)" || exit 1; export WS_DIR
    echo "  mounting WS_DIR        -> /workspace/ws        ($WS_DIR)"; fi
pj="$(read_env PROJECTS_DIR)" || exit 1
if [ -n "$pj" ]; then PROJECTS_DIR="$(validate_mount "$pj" PROJECTS_DIR)" || exit 1; export PROJECTS_DIR
    echo "  mounting PROJECTS_DIR  -> /workspace/projects  ($PROJECTS_DIR)"; fi

# Behind a TLS-inspecting proxy (Cloudflare WARP / Zscaler)? Any PEM in certs/ is trusted at build
# + runtime (see certs/README.md). Advisory only — an empty certs/ is a no-op.
ncerts=$(ls certs/*.crt certs/*.pem 2>/dev/null | wc -l | tr -d ' ')
[ "${ncerts:-0}" -gt 0 ] && echo "  trusting ${ncerts} custom CA cert(s) from certs/ (corporate / TLS-inspecting proxy)"

# Build, then run a supply-chain scan. The scan is ADVISORY by default (prints findings, doesn't
# block — see scan.sh); set TRIVY_STRICT=1 to make it gate the start, or SKIP_TRIVY=1 to skip it.
echo "Building image..."
docker compose build
if [ -n "${SKIP_TRIVY:-}" ]; then
    echo "  (SKIP_TRIVY set — skipping image vulnerability scan)"
else
    TRIVY_SUMMARY=1 ./scan.sh || {
        echo
        echo "STRICT scan failed (see above). Set SKIP_TRIVY=1 to start anyway, or reduce the"
        echo "surface by bumping the base-image digest in the Dockerfile and rebuilding."
        exit 1
    }
fi
docker compose up -d

port="$(grep -E '^TTYD_PORT=' .env | cut -d= -f2)"; port="${port:-7681}"
cat <<EOF

  Claude Code sandbox is running.

  1. Open:  http://127.0.0.1:${port}
  2. Log in with the TTYD_USER / TTYD_PASS from your .env
  3. In the terminal:  claude   ->   /login   ->  paste the code from your browser
     (login persists across restarts)

  Stop with:   docker compose down       Logs:  docker compose logs -f
EOF
