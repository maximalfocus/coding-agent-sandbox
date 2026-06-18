# Log in to the bundled Codex CLI with your ChatGPT/OpenAI subscription, on Windows.
# Uses the DEVICE-AUTH flow (Codex's recommended path for headless/containerized machines): it
# prints a URL + code, you authorize in any browser, and Codex polls OpenAI through the egress
# proxy to finish — no localhost:1455 loopback callback. Saved in the persisted codex volume.
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$svc = "claude-sandbox"

$running = docker compose ps --status running --format '{{.Name}}' 2>$null
if (-not $running) {
    Write-Host "Sandbox isn't running. Start it first:  start-sandbox.cmd"
    exit 1
}

# OpenAI egress must be on, or device-auth polling is refused (403) by the proxy.
docker compose exec -T $svc grep -q "openai" /etc/tinyproxy/filter 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "OpenAI egress is not enabled. Set ALLOW_OPENAI=true in .env, run start-sandbox.cmd,"
    Write-Host "then run this again."
    exit 1
}

Write-Host ""
Write-Host "Starting codex login --device-auth. Codex will print a URL and a short code:"
Write-Host "  1. Open the URL in your browser on this PC."
Write-Host "  2. Enter the code and sign in with your ChatGPT / OpenAI subscription."
Write-Host "  3. Codex polls to finish — the terminal will say it's logged in."
Write-Host ""
Write-Host "Saved in the persisted codex volume, so you only do this once. Ctrl-C to abort."
Write-Host ""

# Run as node so the login lands in /home/node/.codex (persisted) and matches the web-terminal user.
docker compose exec -u node $svc codex login --device-auth
