# Log in to the bundled GitHub CLI (gh) on Windows — the PERMANENT fix for pushing GitHub Actions
# workflow files (.github/workflows/*). A plain repo/Contents PAT cannot push those (GitHub needs
# the `workflow` scope, and a classic PAT's scopes are fixed at creation), but gh's token carries
# `workflow`. Device flow (URL + code in any browser); saved in the persisted gh-config volume so
# you only do this once, and the entrypoint wires git to use it on every start.
$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot '../..')

$svc = "claude-sandbox"

# Guarded: native stderr terminates under $ErrorActionPreference='Stop' whatever the redirect, so
# an unguarded probe throws instead of reporting (issues #111, #117).
$running = $null
try { $running = docker compose ps --status running --format '{{.Name}}' 2>$null } catch { $running = $null }
if (-not $running) {
    Write-Host "Sandbox isn't running. Start it first:  start-sandbox.cmd"
    exit 1
}

# GitHub egress must be on, or device-auth polling is refused by the proxy.
docker compose exec -T $svc grep -qi "github" /etc/tinyproxy/filter 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHub egress is not enabled. Set ALLOW_GITHUB=true in .env, run start-sandbox.cmd,"
    Write-Host "then run this again."
    exit 1
}

Write-Host ""
Write-Host "Starting gh auth login (device flow). When prompted:"
Write-Host "  1. Account: GitHub.com  |  Protocol: HTTPS  |  Authenticate Git: Yes"
Write-Host "  2. 'How would you like to authenticate?' -> Login with a web browser."
Write-Host "  3. gh prints a one-time code + https://github.com/login/device — open it in your"
Write-Host "     browser on this PC, paste the code, and approve (includes the workflow scope)."
Write-Host "  4. gh polls to finish; you'll see 'Logged in as ...'."
Write-Host ""
Write-Host "Saved in the persisted gh-config volume, so you only do this once. Ctrl-C to abort."
Write-Host ""

# Run as node so the login lands in /home/node/.config/gh (persisted) and matches the web-terminal user.
docker compose exec -u node $svc gh auth login --hostname github.com --git-protocol https --scopes workflow
docker compose exec -u node $svc gh auth setup-git --hostname github.com
docker compose exec -u node $svc gh auth status
