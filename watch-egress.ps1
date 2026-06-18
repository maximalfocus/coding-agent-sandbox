# Watch the sandbox's egress audit trail and ALERT the moment a NEW host is refused (403/filtered).
# Mirror of watch-egress.sh. For each new blocked host you get a Windows toast + a console beep, then
# a prompt to evaluate and handle it: allow it (runs ./allow-domain.ps1) or leave it blocked (reject).
#
#   ./watch-egress.ps1              # alert + interactive allow/skip prompt per new refused host
#   ./watch-egress.ps1 -NotifyOnly  # only alert (toast + beep), never prompt — good for background
#
# Allowing here is IMMEDIATE but TEMPORARY (lost on next container restart). For a permanent rule,
# also add the host to EXTRA_ALLOWED_DOMAINS in .env. Ctrl-C to stop watching.
param([switch]$NotifyOnly)
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$SVC = "claude-sandbox"
$LOG = "/var/log/tinyproxy/tinyproxy.log"

$running = docker compose ps --status running --format '{{.Name}}' 2>$null
if ([string]::IsNullOrWhiteSpace($running)) {
    Write-Host "Sandbox isn't running. Start it first:  ./run.ps1"; exit 1
}

function Show-Alert([string]$message) {
    try { [console]::beep(800, 300) } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Warning
        $ni.Visible = $true
        $ni.ShowBalloonTip(8000, "Sandbox blocked egress", $message, [System.Windows.Forms.ToolTipIcon]::Warning)
        Start-Sleep -Milliseconds 250
    } catch {}
}

Write-Host "Watching sandbox egress for refused hosts... (Ctrl-C to stop)"
if ($NotifyOnly) { Write-Host "  (notify-only: will alert but not prompt)" }
$seen = @{}

# -n0 = only lines from now on; -F = keep following across the entrypoint's log rotation.
docker compose exec -T $SVC tail -F -n0 $LOG 2>$null | ForEach-Object {
    $line = $_
    if ($line -notmatch 'refused on filtered') { return }
    if ($line -notmatch 'filtered domain "([^"]+)"') { return }
    $h = $matches[1]
    if ($seen.ContainsKey($h)) { return }   # one alert per host per session
    $seen[$h] = $true
    $ts = (Get-Date).ToString("HH:mm:ss")
    Write-Host ""
    Write-Host "  [$ts] BLOCKED: $h" -ForegroundColor Yellow
    Write-Host "       allow (this run):  ./allow-domain.ps1 $h"
    Write-Host "       allow (permanent): add '$h' to EXTRA_ALLOWED_DOMAINS in .env"
    Show-Alert "$h - blocked. Evaluate & allow if trusted."
    if (-not $NotifyOnly) {
        $ans = Read-Host "       Allow $h now? [y = allow / Enter = skip]"
        if ($ans -eq "y" -or $ans -eq "Y") {
            & "$PSScriptRoot/allow-domain.ps1" $h
            Write-Host "       allowed for this run - add it to .env to make it permanent."
        } else {
            Write-Host "       left blocked (rejected)."
        }
    }
}
