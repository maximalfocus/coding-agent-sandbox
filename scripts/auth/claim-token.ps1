# Move an existing Claude subscription login OUT of the agent-readable config volume and into the
# tinyproxy-only vault, leaving a harmless placeholder behind — the "token isolation" hardening
# (mitm variant only), on Windows. Run once after /login; the agent can then no longer read a usable
# token, while the mitm proxy injects the real one into each Anthropic API call.
#
# Safe to re-run: a no-op once the placeholder is in place, and the mitm entrypoint also does this
# automatically on every container start (so a restart works too).
#
#   .\scripts\auth\claim-token.ps1
$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot '../..')

# Auto-detect which isolation stack is up: the two-container sidecar variant or the single-container
# mitm variant. Claim runs in whichever holds the vault.
#
# Which stack this resolves to is a credential-affecting choice — the claim MOVES a real subscription
# token — so it has to be addressable and visible rather than inferred from whatever is running. A
# Compose call without `-p` cannot see a project started with one, and matching only on the default
# container name could resolve the operator's own stack instead (issue #95). Kept in step with
# scripts/auth/claim-token.sh.
$project = $env:SIDECAR_COMPOSE_PROJECT
$egressName = $env:SIDECAR_EGRESS_CONTAINER_NAME
if (-not $egressName) { $egressName = "claude-sandbox-egress" }

$scope = @()
if ($project) { $scope = @("-p", $project) }

$sidecar = docker compose @scope -f docker-compose.sidecar.yml ps --status running --format '{{.Name}}' 2>$null
$mitm    = docker compose @scope -f docker-compose.mitm.yml ps --status running --format '{{.Name}}' 2>$null
if ($sidecar -match [regex]::Escape($egressName)) {
    $compose = $scope + @("-f", "docker-compose.sidecar.yml"); $svc = "claude-sandbox-egress"
    $container = $egressName
} elseif ($mitm -match "claude-sandbox-mitm") {
    $compose = $scope + @("-f", "docker-compose.mitm.yml"); $svc = "claude-sandbox-mitm"
    $container = "claude-sandbox-mitm"
} else {
    $where = ""
    if ($project) { $where = " in project '$project'" }
    Write-Host "No isolation sandbox is running$where. Start one first:"
    Write-Host '  $env:ANTHROPIC_TOKEN_ISOLATION="true"; docker compose -f docker-compose.mitm.yml up -d --build'
    Write-Host '  # or the experimental sidecar: docker compose -f docker-compose.sidecar.yml up -d --build'
    exit 1
}

# Say which stack is about to be acted on, rather than leaving the operator to infer it.
$where = ""
if ($project) { $where = "  (project '$project')" }
Write-Host "Claiming into: $container$where"

# `-p` does not scope this project's volumes, which are named explicitly so a renamed checkout never
# orphans a login, so a run can declare a project and still mount the operator's own login (#93).
if ($project) {
    $mounted = docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' $container 2>$null
    $defaults = Select-String -Path docker-compose.sidecar.yml -Pattern 'name:\s*"?\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}' |
                ForEach-Object { $_.Matches[0].Groups[1].Value }
    $shared = @($mounted | Where-Object { $defaults -contains $_ })
    if ($shared.Count -gt 0 -and $env:SIDECAR_ALLOW_SHARED_VOLUMES -ne "true") {
        Write-Error "REFUSING: project '$project' mounts the operator's own volumes: $($shared -join ' ')
  A claim here would move the real login, not this stack's. Set the volume variables documented at
  the top of sidecar-smoketest.sh, or `$env:SIDECAR_ALLOW_SHARED_VOLUMES=`"true`"."
        exit 1
    }
}

# Runs as root inside the container: it must write both the tinyproxy-owned vault and the node-owned
# placeholder. The real token never leaves the container.
docker compose @compose exec -u root $svc /usr/local/bin/claim-token
