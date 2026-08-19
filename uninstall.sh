#!/usr/bin/env bash
# uninstall.sh — the counterpart to setup.sh: removes everything this sandbox
# created on the host, so you can start from a clean slate (or fully remove it).
#
# Removes ONLY sandbox-owned resources (all have fixed, project-name-independent
# names) plus this repo directory. It NEVER touches your host personal/work trees
# (PERSONAL_DIR / WORK_DIR) or your ~/.docker login.
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

# --- What belongs to the sandbox --------------------------------------------
# Resolved from the SAME variables the compose files use, defaulting to the fixed names so an
# existing operator sees no change. Fixed names alone meant this script could only ever act on the
# DEFAULT installation, so its removal half could not be exercised on a machine that also held a
# real one — the resources it removes include the operator's login. That is the same hazard
# `docker-compose.yml` records for `down -v` (issue #123).
# First non-empty of the named variables, else the trailing literal default. Several volumes are
# declared by two compose files under two different variable names for the SAME default, so both
# have to be honoured or an addressed run would fall back to the operator's (issue #125).
pick() {
    local default="${!#}" n
    for n in "$@"; do
        [ "$n" = "$default" ] && break
        [ -n "${!n:-}" ] && { printf '%s' "${!n}"; return; }
    done
    printf '%s' "$default"
}

CONTAINERS=(
  "$(pick SANDBOX_CONTAINER_NAME        claude-sandbox)"
  "$(pick SANDBOX_MITM_CONTAINER_NAME   claude-sandbox-mitm)"
  "$(pick SIDECAR_EGRESS_CONTAINER_NAME claude-sandbox-egress)"
  "$(pick SIDECAR_AGENT_CONTAINER_NAME  claude-sandbox-node)"
  "$(pick NESTED_DOCKER_CONTAINER_NAME  claude-sandbox-dind)"
)
# Every volume any tracked compose file declares. The three credential ones below were absent until
# issue #125: an uninstall left a real Claude token, a DeepSeek API key and the intercept CA's
# private key on the host while reporting that it had removed everything the sandbox created.
# scripts/test-uninstall-inventory.sh holds this set against the compose files.
VOLUMES=(
  "$(pick SANDBOX_CONFIG_VOLUME_NAME SIDECAR_CONFIG_VOLUME_NAME       coding-agent-sandbox-config)"
  "$(pick SANDBOX_CODEX_VOLUME_NAME                                   coding-agent-sandbox-codex)"
  "$(pick SANDBOX_GH_VOLUME_NAME                                      coding-agent-sandbox-gh)"
  "$(pick SANDBOX_WORKSPACE_VOLUME_NAME                               coding-agent-sandbox-workspace)"
  "$(pick SANDBOX_WORK_VOLUME_NAME                                    coding-agent-sandbox-work)"
  "$(pick SANDBOX_PERSONAL_VOLUME_NAME                                coding-agent-sandbox-personal)"
  "$(pick SANDBOX_AUDIT_VOLUME_NAME                                   coding-agent-sandbox-audit)"
  "$(pick SANDBOX_MITM_AUDIT_VOLUME_NAME SIDECAR_AUDIT_VOLUME_NAME    coding-agent-sandbox-audit-mitm)"
  "$(pick SANDBOX_TRIVY_CACHE_VOLUME_NAME                             coding-agent-sandbox-trivy-cache)"
  "$(pick SANDBOX_MITM_SECRET_VOLUME_NAME SIDECAR_CLAUDE_SECRET_VOLUME_NAME coding-agent-sandbox-secret)"
  "$(pick DEEPSEEK_SECRET_VOLUME_NAME                                 coding-agent-sandbox-deepseek-secret)"
  "$(pick SIDECAR_CA_VOLUME_NAME                                      coding-agent-sandbox-mitm-ca)"
  "$(pick SANDBOX_AWS_VOLUME_NAME                                     coding-agent-sandbox-aws)"
  "$(pick NESTED_DOCKER_STORAGE_VOLUME_NAME                           coding-agent-sandbox-nested-docker)"
)
# Pre-WORK_DIR naming. No compose file declares it any more, so it exists only on hosts that ran an
# old version — which by definition is the DEFAULT installation. An addressed run never sweeps it.
LEGACY_VOLUMES=(coding-agent-sandbox-ws)
# The compose network is <project>_default; claude-safe-net is created on first use by the optional
# `claude-safe` shell helper (a `docker run` on its own user-defined network).
NETWORKS=(
  "${COMPOSE_PROJECT_NAME:-coding-agent-sandbox}_default"
  "claude-safe-net"
)
# The image tags are NOT parameterised in the compose files, so every installation on a host shares
# them. An addressed run therefore keeps them: removing a shared image is exactly the "touched a
# resource that was not mine" failure this addressability exists to make impossible.
IMAGES=(coding-agent-sandbox:latest coding-agent-sandbox-mitm:latest)

# --- Which installation is being removed? ------------------------------------
# Any override means "not the default installation". A PARTIAL override is the dangerous case: it
# resolves some names to a disposable stack and the rest to the operator's, so a single run would
# remove both. Refuse rather than guess — the same fail-closed rule scripts/stack-guard.sh applies.
SANDBOX_VARS=(
  SANDBOX_CONTAINER_NAME SANDBOX_MITM_CONTAINER_NAME
  SIDECAR_EGRESS_CONTAINER_NAME SIDECAR_AGENT_CONTAINER_NAME NESTED_DOCKER_CONTAINER_NAME
  SANDBOX_CONFIG_VOLUME_NAME SANDBOX_CODEX_VOLUME_NAME SANDBOX_GH_VOLUME_NAME
  SANDBOX_WORKSPACE_VOLUME_NAME SANDBOX_WORK_VOLUME_NAME SANDBOX_PERSONAL_VOLUME_NAME
  SANDBOX_AUDIT_VOLUME_NAME SANDBOX_MITM_AUDIT_VOLUME_NAME SANDBOX_TRIVY_CACHE_VOLUME_NAME
  SANDBOX_MITM_SECRET_VOLUME_NAME DEEPSEEK_SECRET_VOLUME_NAME SIDECAR_CA_VOLUME_NAME
  SANDBOX_AWS_VOLUME_NAME NESTED_DOCKER_STORAGE_VOLUME_NAME COMPOSE_PROJECT_NAME
)
ADDRESSED=0
set_vars=(); unset_vars=()
for v in "${SANDBOX_VARS[@]}"; do
    if [ -n "${!v:-}" ]; then set_vars+=("$v"); else unset_vars+=("$v"); fi
done
if [ "${#set_vars[@]}" -gt 0 ]; then
    ADDRESSED=1
    if [ "${#unset_vars[@]}" -gt 0 ]; then
        echo "REFUSING: this run addresses a named installation, but these are unset:" >&2
        printf '  %s\n' "${unset_vars[@]}" >&2
        echo "Each unset name falls back to the DEFAULT — the operator's — so one run would remove" >&2
        echo "resources from two installations. Set all of them, or none of them." >&2
        exit 1
    fi
fi

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

Removes ONLY sandbox-owned Docker resources + this repo directory.

Names come from the same SANDBOX_* variables the compose files use. Set ALL of them
(and COMPOSE_PROJECT_NAME) to remove one named installation instead of the default;
a partial override is refused, because the unset names fall back to the default
installation's. An addressed run keeps the shared image tags, the host Docker engine
and this directory, which belong to the host rather than to that installation.
NEVER touches your host personal/work trees (PERSONAL_DIR / WORK_DIR) or your ~/.docker login.

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
# An addressed run removes ONE named installation and nothing else. The shared, fixed-name
# resources — the image tags, the host Docker engine, and this repo directory — belong to the host
# rather than to that installation, so they are never in scope for it (issue #123).
if [ "$ADDRESSED" -eq 1 ]; then
    KEEP_IMAGES=1
    REMOVE_DOCKER_ENGINE=0
    FORCE_ENGINE=0
    KEEP_DIR=1
    # claude-safe-net is created on first use by the optional `claude-safe` helper and is shared by
    # every installation on the host, so an addressed run leaves it alone too.
    NETWORKS=("${COMPOSE_PROJECT_NAME}_default")
    LEGACY_VOLUMES=()
fi
# Guarded because macOS ships bash 3.2, where expanding an EMPTY array under `set -u` is an
# "unbound variable" error — which an addressed run hits, since it clears the legacy sweep.
if [ "${#LEGACY_VOLUMES[@]}" -gt 0 ]; then
    VOLUMES=("${VOLUMES[@]}" "${LEGACY_VOLUMES[@]}")
fi

have() { command -v "$1" >/dev/null 2>&1; }

# --- Preview -----------------------------------------------------------------
say "coding-agent-sandbox uninstall"
say "=============================="
say ""
if [ "$ADDRESSED" -eq 1 ]; then
    say "Addressing the named installation '${COMPOSE_PROJECT_NAME}' — not the default one."
    say "  (images, the host Docker engine and this directory are shared, so they are left alone)"
    say ""
fi
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
say "NOT touched: your host personal/work trees (PERSONAL_DIR / WORK_DIR) and your ~/.docker login."
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
echo "  git clone https://github.com/maximalfocus/coding-agent-sandbox.git \"$REPO_DIR\""
echo "  cd \"$REPO_DIR\" && ./setup.sh"
rm -f "$remover"
EOF
    chmod +x "$remover"
    cd /                      # leave the dir we're about to delete
    exec "$remover"           # replace this process; the repo (incl. this file) is now safe to remove
fi

say ""
say "Done."
