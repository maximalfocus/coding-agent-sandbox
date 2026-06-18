# Log in to the bundled Codex CLI with your ChatGPT/OpenAI subscription, on Windows.
# Mirrors codex-login.sh. Codex's OAuth callback server runs on 127.0.0.1:1455 INSIDE the
# container; this bridges it (socat -> the published 11455 port) so the browser redirect to
# localhost:1455 reaches it and the login completes. The login persists in the codex volume.
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$svc = "claude-sandbox"

$running = docker compose ps --status running --format '{{.Name}}' 2>$null
if (-not $running) {
    Write-Host "Sandbox isn't running. Start it first:  start-sandbox.cmd"
    exit 1
}

# OpenAI egress must be on, or the token exchange is refused (403) by the proxy.
docker compose exec -T $svc grep -q "openai" /etc/tinyproxy/filter 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "OpenAI egress is not enabled. Set ALLOW_OPENAI=true in .env, run start-sandbox.cmd,"
    Write-Host "then run this again."
    exit 1
}

# Bridge Codex's loopback callback (1455) to the container's published port (11455). Idempotent.
# `pgrep -x socat` matches by process name; `pgrep -f` would self-match this guard's own command
# line (it contains "socat") and socat would never start.
docker compose exec -d $svc sh -c 'pgrep -x socat >/dev/null 2>&1 || socat TCP-LISTEN:11455,fork,reuseaddr TCP:127.0.0.1:1455'

Write-Host ""
Write-Host "Starting codex login. When it prints a URL:"
Write-Host "  1. Open it in your browser on this PC."
Write-Host "  2. Sign in with your ChatGPT / OpenAI subscription."
Write-Host "  3. It redirects to http://localhost:1455/... and the CLI completes the login."
Write-Host ""
Write-Host "The login is saved in the codex volume, so you only do this once. Ctrl-C to abort."
Write-Host ""

docker compose exec $svc codex login
