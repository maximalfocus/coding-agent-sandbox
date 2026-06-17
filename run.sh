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

# Guard the mounted workspace: refuse broad/sensitive dirs so a typo in WORKSPACE_DIR can't
# expose your whole home or credentials to the sandbox (the compose mount has no guard itself).
# Parse robustly: skip comments, reject duplicate keys (ambiguous vs Compose), strip quotes.
wd_lines="$(grep -E '^[[:space:]]*WORKSPACE_DIR=' .env | grep -vE '^[[:space:]]*#' || true)"
if [ "$(printf '%s\n' "$wd_lines" | grep -c .)" -gt 1 ]; then
    echo "Multiple WORKSPACE_DIR entries in .env — ambiguous; keep exactly one."; exit 1
fi
wd="$(printf '%s' "$wd_lines" | head -1 | cut -d= -f2-)"; wd="${wd:-./workspace}"
wd="$(printf '%s' "$wd" | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"   # strip quotes
wd_abs="$(cd "$wd" 2>/dev/null && pwd -P)" || { echo "WORKSPACE_DIR '$wd' does not exist."; exit 1; }
# Canonicalize $HOME too, so the comparison holds even when home is reached via a symlink.
home_abs="$(cd "$HOME" 2>/dev/null && pwd -P)"; home_abs="${home_abs:-$HOME}"
for bad in "$home_abs" / "$home_abs/.ssh" "$home_abs/.aws" "$home_abs/.gnupg" "$home_abs/.config" \
           "$home_abs/.kube" "$home_abs/.docker" "$home_abs/.gcloud" "$home_abs/.azure"; do
    if [ "$wd_abs" = "$bad" ] || case "$wd_abs" in "$bad"/*) true;; *) false;; esac; then
        echo "Refusing to mount sensitive/broad WORKSPACE_DIR '$wd_abs'. Point it at a project dir."; exit 1
    fi
done
case "$home_abs" in "$wd_abs"/*) echo "Refusing: WORKSPACE_DIR '$wd_abs' contains your home dir."; exit 1;; esac

# Mount the exact path we validated (shell env overrides .env in Compose). Avoids a check-vs-mount
# mismatch if the .env value is relative or a symlink that resolves elsewhere.
export WORKSPACE_DIR="$wd_abs"

# Build, then gate on a supply-chain scan BEFORE starting the container, so a known-vulnerable
# image never gets run. Set SKIP_TRIVY=1 to bypass (e.g. offline with no scanner DB cached).
echo "Building image..."
docker compose build
if [ -n "${SKIP_TRIVY:-}" ]; then
    echo "  (SKIP_TRIVY set — skipping image vulnerability scan)"
else
    ./scan.sh || {
        echo
        echo "Image scan found ${TRIVY_SEVERITY:-HIGH,CRITICAL} vulnerabilities (see above)."
        echo "Fix by bumping the base-image digest / packages in the Dockerfile and rebuilding,"
        echo "or re-run with SKIP_TRIVY=1 to start anyway."
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
