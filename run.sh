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
# Refuse your WHOLE home or the filesystem root (exact match) — but DO allow a normal project dir
# that lives under home, e.g. ~/code/app or ~/projects (that's the common case).
if [ "$wd_abs" = "$home_abs" ] || [ "$wd_abs" = "/" ]; then
    echo "Refusing to mount '$wd_abs' (your whole home or filesystem root). Point it at a project dir."; exit 1
fi
# Refuse known credential/config dirs and anything inside them (prefix match).
for bad in "$home_abs/.ssh" "$home_abs/.aws" "$home_abs/.gnupg" "$home_abs/.config" \
           "$home_abs/.kube" "$home_abs/.docker" "$home_abs/.gcloud" "$home_abs/.azure"; do
    if [ "$wd_abs" = "$bad" ] || case "$wd_abs" in "$bad"/*) true;; *) false;; esac; then
        echo "Refusing to mount sensitive WORKSPACE_DIR '$wd_abs'. Point it at a project dir."; exit 1
    fi
done
# Refuse a dir that CONTAINS your home (an ancestor like / or /Users).
case "$home_abs" in "$wd_abs"/*) echo "Refusing: WORKSPACE_DIR '$wd_abs' contains your home dir."; exit 1;; esac

# Mount the exact path we validated (shell env overrides .env in Compose). Avoids a check-vs-mount
# mismatch if the .env value is relative or a symlink that resolves elsewhere.
export WORKSPACE_DIR="$wd_abs"

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
