# Move an existing Claude subscription login OUT of the agent-readable config volume and into the
# tinyproxy-only vault, leaving a harmless placeholder behind — the "token isolation" hardening
# (mitm variant only), on Windows. Run once after /login; the agent can then no longer read a usable
# token, while the mitm proxy injects the real one into each Anthropic API call.
#
# Safe to re-run: a no-op once the placeholder is in place, and the mitm entrypoint also does this
# automatically on every container start (so a restart works too).
#
#   .\claim-token.ps1
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

# Auto-detect which isolation stack is up: the two-container sidecar variant or the single-container
# mitm variant. Claim runs in whichever holds the vault.
$sidecar = docker compose -f docker-compose.sidecar.yml ps --status running --format '{{.Name}}' 2>$null
$mitm    = docker compose -f docker-compose.mitm.yml ps --status running --format '{{.Name}}' 2>$null
if ($sidecar -match "claude-sandbox-egress") {
    $compose = @("-f", "docker-compose.sidecar.yml"); $svc = "claude-sandbox-egress"
} elseif ($mitm -match "claude-sandbox-mitm") {
    $compose = @("-f", "docker-compose.mitm.yml"); $svc = "claude-sandbox-mitm"
} else {
    Write-Host "No isolation sandbox is running. Start one first:"
    Write-Host '  $env:ANTHROPIC_TOKEN_ISOLATION="true"; docker compose -f docker-compose.mitm.yml up -d --build'
    Write-Host '  # or the experimental sidecar: docker compose -f docker-compose.sidecar.yml up -d --build'
    exit 1
}

# Runs as root inside the container: it must write both the tinyproxy-owned vault and the node-owned
# placeholder. The real token never leaves the container.
docker compose @compose exec -u root $svc /usr/local/bin/claim-token
