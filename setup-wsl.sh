#!/usr/bin/env bash
# setup-wsl.sh - one-shot provisioning to run this sandbox inside WSL2 Ubuntu on a Windows laptop
# (including SEED laptops behind Cloudflare WARP). Automates the host-side steps from
# docs/wsl-warp.md so colleagues don't have to do them by hand:
#   - /etc/wsl.conf : metadata automount (so git/chmod work on /mnt/c) + systemd (for dockerd)
#   - /etc/gai.conf : prefer IPv4 (WARP hands out unreachable IPv6, else apt/curl stall)
#   - Docker        : docker.io + docker-compose-v2 + docker-buildx, enabled and started
#   - docker group  : adds you so `docker` works without sudo
#
# Run it from the repo root INSIDE a WSL Ubuntu shell:
#   ./setup-wsl.sh
#
# Enabling systemd takes one `wsl --shutdown` from Windows PowerShell; the script tells you when.
# It is idempotent - safe to re-run. When it finishes:
#   ./certs/fetch-warp-ca.sh   # only if behind Cloudflare WARP / a TLS-inspecting proxy
#   ./setup.sh                 # writes .env, builds, and starts the sandbox
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '%s\n' "$@"; }

# Must be inside WSL. (macOS/Linux: ./setup.sh ; Windows + Docker Desktop: setup-windows.cmd)
if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    say "This script is for WSL2 Ubuntu. On macOS/Linux use ./setup.sh; on Windows + Docker Desktop use setup-windows.cmd."
    exit 1
fi

# Use sudo unless we're already root.
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    if ! command -v sudo >/dev/null 2>&1; then
        say "Need root: run as root or install sudo first."; exit 1
    fi
    SUDO="sudo"
fi

# 1. /etc/wsl.conf - metadata automount + systemd.
desired_wslconf="$(printf '[automount]\noptions = "metadata"\n\n[boot]\nsystemd=true')"
if [ "$(cat /etc/wsl.conf 2>/dev/null || true)" != "$desired_wslconf" ]; then
    say "==> Writing /etc/wsl.conf (metadata automount + systemd)"
    printf '%s\n' "$desired_wslconf" | $SUDO tee /etc/wsl.conf >/dev/null
fi

# 2. /etc/gai.conf - prefer IPv4 (the default ships this rule COMMENTED; add an active one).
if ! grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf 2>/dev/null; then
    say "==> Adding IPv4 precedence to /etc/gai.conf"
    echo 'precedence ::ffff:0:0/96  100' | $SUDO tee -a /etc/gai.conf >/dev/null
fi

# 3. systemd must be PID 1 before we manage the Docker daemon. If wsl.conf was just enabled, it
#    needs one `wsl --shutdown` from Windows to take effect (also activates the metadata mount).
if [ "$(ps -p 1 -o comm= 2>/dev/null || true)" != "systemd" ]; then
    say ""
    say "systemd is not active yet (required for the Docker daemon, and the /mnt/c metadata mount"
    say "needs the same restart). Finish enabling it:"
    say "  1. In Windows PowerShell:   wsl --shutdown"
    say "  2. Reopen Ubuntu and re-run: ./setup-wsl.sh"
    exit 0
fi

# 4. Docker Engine + Compose v2 + buildx. docker.io tracks even pre-release Ubuntu codenames;
#    docker-compose-v2 is the `docker compose` plugin run.sh needs; docker-buildx is the builder.
if ! command -v docker >/dev/null 2>&1; then
    say "==> Installing Docker (docker.io + docker-compose-v2 + docker-buildx)"
    $SUDO apt-get update
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 docker-buildx
fi
say "==> Enabling + starting the Docker daemon"
$SUDO systemctl enable --now docker

# 5. docker group so `docker` works without sudo (takes effect in a NEW shell).
group_added=0
if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    say "==> Adding $USER to the docker group"
    $SUDO usermod -aG docker "$USER"
    group_added=1
fi

say ""
say "WSL provisioning done:"
say "  /etc/wsl.conf : metadata + systemd"
say "  /etc/gai.conf : IPv4 preferred"
say "  docker        : $(docker --version 2>/dev/null || echo installed)"
say "  compose       : $(docker compose version 2>/dev/null | head -1 || echo installed)"
if [ "$group_added" -eq 1 ]; then
    say ""
    say "IMPORTANT: open a NEW WSL shell (close + reopen Ubuntu) so 'docker' works without sudo."
fi
say ""
say "Next steps:"
say "  1. Behind Cloudflare WARP / a TLS-inspecting proxy?   ./certs/fetch-warp-ca.sh"
say "  2. ./setup.sh"
say "     (at the prompts, point PERSONAL_DIR / WORK_DIR at e.g. /mnt/c/Users/<you>/personal"
say "      and /mnt/c/Users/<you>/work so they're visible from Windows)"
