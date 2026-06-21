#!/usr/bin/env bash
# uninstall.sh — the counterpart to setup.sh: removes everything this sandbox
# created on the host, so you can start from a clean slate (or fully remove it).
#
# Removes ONLY sandbox-owned resources (all have fixed, project-name-independent
# names) plus this repo directory. It NEVER touches your host ~/ws, ~/projects,
# or your ~/.docker login.
#
#   ./uninstall.sh                    # prompts, then full wipe (incl. Docker engine)
#   ./uninstall.sh -y                 # no prompt
#   ./uninstall.sh --keep-docker-engine   # keep OrbStack/Docker Desktop installed
#   ./uninstall.sh --keep-dir         # docker teardown only, keep this directory
#
# Self-deleting: the repo-directory removal is the last step and re-execs a tiny
# remover from a temp dir, so deleting this script mid-run is safe. To reinstall:
#   git clone git@github.com:maximalfocus/coding-agent-sandbox.git && ./setup.sh
# ---------------------------------------------------------------------------
set -euo pipefail

# This script lives at the repo root, so the repo dir is just where it sits.
REPO_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# Provenance marker: setup.sh writes this iff IT installed OrbStack. Lives outside the repo so it
# survives the repo deletion. Engine removal is gated on it (see below) — we don't uninstall a
# Docker engine that pre-existed this sandbox unless --remove-docker-engine forces it.
ENGINE_MARKER="$HOME/.coding-agent-sandbox/installed-orbstack"

# --- What belongs to the sandbox (fixed names from both compose files) -------
CONTAINERS=(claude-sandbox claude-sandbox-mitm)
IMAGES=(coding-agent-sandbox:latest coding-agent-sandbox-mitm:latest)
VOLUMES=(
  coding-agent-sandbox-config
  coding-agent-sandbox-codex
  coding-agent-sandbox-gh
  coding-agent-sandbox-ws
  coding-agent-sandbox-audit
  coding-agent-sandbox-audit-mitm
  coding-agent-sandbox-trivy-cache
)
# coding-agent-sandbox_default = the compose network; claude-safe-net = created on first use by the
# optional `claude-safe` shell helper (a `docker run` on its own user-defined network).
NETWORKS=(coding-agent-sandbox_default claude-safe-net)

# --- Flags -------------------------------------------------------------------
ASSUME_YES=0
KEEP_DIR=0
KEEP_IMAGES=0
PRUNE_DANGLING=0
REMOVE_DOCKER_ENGINE=1   # default: remove the engine, but ONLY if this sandbox installed it (marker)
FORCE_ENGINE=0           # --remove-docker-engine: uninstall the engine even without the marker
SKIP_DOCKER=0

usage() {
    cat <<'EOF'
uninstall.sh — remove everything this sandbox created on the host.

Removes ONLY sandbox-owned Docker resources (fixed names) + this repo directory.
NEVER touches your host ~/ws, ~/projects, or your ~/.docker login.

Usage:
  ./uninstall.sh [flags]

Flags:
  -y, --yes               Don't prompt for confirmation.
      --keep-dir          Tear down Docker resources but keep this directory.
      --keep-images       Keep the built images (faster re-test; skips a rebuild).
      --keep-docker-engine    Never touch OrbStack / Docker Desktop.
      --remove-docker-engine  Force-uninstall OrbStack / Docker Desktop even if this sandbox didn't
                              install it (default only removes an engine it installed itself).
      --prune-dangling    Also `docker image prune -f` (removes ALL dangling layers, host-wide).
      --skip-docker       Do nothing to Docker at all (no resources, no engine); only remove the dir.
  -h, --help              Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes)               ASSUME_YES=1 ;;
        --keep-dir)             KEEP_DIR=1 ;;
        --keep-images)          KEEP_IMAGES=1 ;;
        --keep-docker-engine)   REMOVE_DOCKER_ENGINE=0 ;;
        --remove-docker-engine) REMOVE_DOCKER_ENGINE=1; FORCE_ENGINE=1 ;;
        --prune-dangling)       PRUNE_DANGLING=1 ;;
        --skip-docker)          SKIP_DOCKER=1 ;;
        -h|--help)              usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '%s\n' "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- Preview -----------------------------------------------------------------
say "coding-agent-sandbox uninstall"
say "=============================="
say ""
if [ "$SKIP_DOCKER" -eq 0 ]; then
    say "Docker resources to remove:"
    say "  containers: ${CONTAINERS[*]}"
    [ "$KEEP_IMAGES" -eq 1 ] && say "  images:     (kept — --keep-images)" || say "  images:     ${IMAGES[*]}"
    say "  volumes:    ${VOLUMES[*]}   <-- includes your sandbox Claude/Codex/gh LOGIN; you'll log in again"
    say "  network:    ${NETWORKS[*]}"
else
    say "Docker: skipped (--skip-docker)."
fi
if [ "$KEEP_DIR" -eq 1 ]; then
    say "Directory:  kept (--keep-dir)."
else
    say "Directory:  $REPO_DIR   (this whole repo)"
fi
if [ "$SKIP_DOCKER" -eq 1 ] || [ "$REMOVE_DOCKER_ENGINE" -eq 0 ]; then
    say "Docker engine: kept."
elif [ "$FORCE_ENGINE" -eq 1 ]; then
    say "Docker engine: OrbStack / Docker Desktop will be UNINSTALLED (forced)."
elif [ -f "$ENGINE_MARKER" ]; then
    say "Docker engine: OrbStack will be UNINSTALLED (this sandbox installed it; pass --keep-docker-engine to keep)."
else
    say "Docker engine: kept — it pre-existed this sandbox (no install marker). Use --remove-docker-engine to force."
fi
say ""
say "NOT touched: your host ~/ws, ~/projects, and your ~/.docker login."
say ""

if [ "$ASSUME_YES" -eq 0 ]; then
    printf 'Proceed? [y/N]: '
    read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) say "Aborted."; exit 0 ;; esac
fi

# --- Docker teardown ---------------------------------------------------------
if [ "$SKIP_DOCKER" -eq 0 ]; then
    if ! have docker; then
        say ""
        say "! docker CLI not found — skipping Docker teardown. Resources (if any) remain."
    elif ! docker info >/dev/null 2>&1; then
        say ""
        say "! Docker daemon isn't running. Start OrbStack / Docker Desktop and re-run,"
        say "  or pass --skip-docker to only remove the directory."
        exit 1
    else
        # Graceful compose down first (handles anything the explicit lists miss).
        say ""
        say "==> docker compose down (default + mitm stacks)"
        ( cd "$REPO_DIR" && docker compose down --remove-orphans 2>/dev/null ) || true
        ( cd "$REPO_DIR" && docker compose -f docker-compose.mitm.yml down --remove-orphans 2>/dev/null ) || true

        say "==> Removing containers"
        for c in "${CONTAINERS[@]}"; do
            if docker ps -aq -f "name=^${c}$" | grep -q .; then
                docker rm -f "$c" >/dev/null 2>&1 && say "    removed container $c" || say "    (could not remove $c)"
            fi
        done

        say "==> Removing volumes (logins + audit logs live here)"
        for v in "${VOLUMES[@]}"; do
            if docker volume ls -q -f "name=^${v}$" | grep -q .; then
                docker volume rm "$v" >/dev/null 2>&1 && say "    removed volume $v" || say "    (in use? could not remove $v)"
            fi
        done

        if [ "$KEEP_IMAGES" -eq 0 ]; then
            say "==> Removing images"
            for i in "${IMAGES[@]}"; do
                if docker image inspect "$i" >/dev/null 2>&1; then
                    docker image rm -f "$i" >/dev/null 2>&1 && say "    removed image $i" || say "    (could not remove $i)"
                fi
            done
        fi

        say "==> Removing network"
        for n in "${NETWORKS[@]}"; do
            if docker network ls -q -f "name=^${n}$" | grep -q .; then
                docker network rm "$n" >/dev/null 2>&1 && say "    removed network $n" || say "    (could not remove $n)"
            fi
        done

        if [ "$PRUNE_DANGLING" -eq 1 ]; then
            say "==> Pruning dangling images (host-wide)"
            docker image prune -f >/dev/null 2>&1 || true
        fi
    fi
fi

# --- Optional: remove the Docker engine --------------------------------------
# Only when the user didn't ask to skip Docker, AND either this sandbox installed the engine
# (marker present) or removal was forced. We never silently uninstall a pre-existing engine.
if [ "$SKIP_DOCKER" -eq 0 ] && [ "$REMOVE_DOCKER_ENGINE" -eq 1 ]; then
    if [ "$FORCE_ENGINE" -eq 1 ] || [ -f "$ENGINE_MARKER" ]; then
        say ""
        say "==> Uninstalling Docker engine (OrbStack / Docker Desktop)"
        engine_removed=0
        if have brew; then
            brew uninstall --cask orbstack 2>/dev/null && { say "    uninstalled OrbStack"; engine_removed=1; } || say "    (OrbStack not installed via brew)"
            brew uninstall --cask docker   2>/dev/null && { say "    uninstalled Docker Desktop"; engine_removed=1; } || say "    (Docker Desktop not installed via brew)"
        else
            say "    Homebrew not found — uninstall OrbStack/Docker Desktop manually."
        fi
        # Only clear the provenance marker if we ACTUALLY removed the engine — otherwise a failed or
        # still-needed removal could be retried by the default (marker-gated) path next run.
        if [ "$engine_removed" -eq 1 ]; then
            rm -f "$ENGINE_MARKER" 2>/dev/null || true
            rmdir "$(dirname "$ENGINE_MARKER")" 2>/dev/null || true
        else
            say "    (kept the install marker — nothing was actually uninstalled)"
        fi
    else
        say ""
        say "==> Docker engine: leaving it installed — it pre-existed this sandbox (no marker at"
        say "    $ENGINE_MARKER). Re-run with --remove-docker-engine to uninstall it anyway."
    fi
fi

# --- Advisory: the optional claude-safe shell helper -------------------------
# `claude-safe` is a function users add to ~/.zshrc by hand (per the README); setup.sh never writes
# it, so we don't edit your shell rc files to remove it — just flag it so you can.
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$rc" ] && grep -q 'claude-safe' "$rc" 2>/dev/null; then
        say ""
        say "Note: a 'claude-safe' function is present in $rc. This uninstaller doesn't edit shell"
        say "      rc files — delete that function by hand if you no longer want it."
    fi
done

# --- Directory removal (LAST — this script self-destructs) -------------------
# rm -rf'ing the dir we're running from is unsafe while bash may still read this
# file, so hand the removal to a tiny remover that runs from a temp dir.
if [ "$KEEP_DIR" -eq 0 ]; then
    # Sanity guard so a corrupted REPO_DIR can't nuke home or root.
    home_abs="$(cd "$HOME" && pwd -P)"
    if [ "$REPO_DIR" = "/" ] || [ "$REPO_DIR" = "$home_abs" ] || [ -z "$REPO_DIR" ]; then
        say ""; say "! Refusing to delete '$REPO_DIR' — leaving the directory in place."
        exit 1
    fi
    say ""
    say "==> Removing directory $REPO_DIR"
    remover="$(mktemp "${TMPDIR:-/tmp}/cas-uninstall.XXXXXX")"
    cat > "$remover" <<EOF
#!/bin/sh
rm -rf "$REPO_DIR" 2>/dev/null
if [ -e "$REPO_DIR" ]; then
    echo "    WARNING: could not fully remove $REPO_DIR — check permissions/locks and delete it manually." >&2
    rm -f "$remover"
    exit 1
fi
echo "    removed $REPO_DIR"
echo ""
echo "Done. The Mac is clean. To reinstall:"
echo "  git clone git@github.com:maximalfocus/coding-agent-sandbox.git \"$REPO_DIR\""
echo "  cd \"$REPO_DIR\" && ./setup.sh"
rm -f "$remover"
EOF
    chmod +x "$remover"
    cd /                      # leave the dir we're about to delete
    exec "$remover"           # replace this process; the repo (incl. this file) is now safe to remove
fi

say ""
say "Done."
