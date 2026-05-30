# Open a local terminal INSIDE the running sandbox (Windows PowerShell).
#   ./shell.ps1            # fresh shell in /workspace
#   ./shell.ps1 -Attach    # attach to the same tmux session the browser shows
param([switch]$Attach)
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$running = docker compose ps --status running --format '{{.Name}}' 2>$null
if ([string]::IsNullOrWhiteSpace($running)) {
    Write-Host "Sandbox isn't running. Start it first:  ./run.ps1"; exit 1
}

if ($Attach) {
    docker compose exec -u node claude-sandbox tmux new-session -A -s claude
} else {
    docker compose exec -u node -w /workspace claude-sandbox bash -l
}
