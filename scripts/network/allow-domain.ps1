# Hot-add domain(s) to the RUNNING sandbox's allowlist without restarting (Windows PowerShell).
# Mirror of allow-domain.sh. Effect is immediate but TEMPORARY — for a permanent rule, also add the
# host to EXTRA_ALLOWED_DOMAINS in .env (it's re-applied on every container (re)start).
#
#   ./scripts/network/allow-domain.ps1 pypi.org files.pythonhosted.org
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Domains)
$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot '../..')

if (-not $Domains -or $Domains.Count -lt 1) {
    Write-Host "usage: ./scripts/network/allow-domain.ps1 <domain> [domain ...]"; exit 1
}
$running = docker compose ps --status running --format '{{.Name}}' 2>$null
if ([string]::IsNullOrWhiteSpace($running)) {
    Write-Host "Sandbox isn't running. Start it first:  ./run.ps1"; exit 1
}

$added = 0
foreach ($d in $Domains) {
    # Validate as a strict multi-label hostname BEFORE building a regex — reject TLDs / IP literals
    # so input like "com" or "1.2.3.4" can't widen the allowlist to ~everything.
    if ($d -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' -or $d -match '^[0-9.]+$') {
        Write-Host "skip invalid domain: '$d' (need a multi-label hostname, not a TLD or IP)"; continue
    }
    $esc = $d -replace '\.', '\.'
    $line = '(^|\.)' + $esc + '$'
    $added = 1
    # Same anchored pattern the entrypoint uses. Pipe the line in via stdin (mirrors allow-domain.sh)
    # to avoid PowerShell/native argument-quoting pitfalls.
    $line | docker compose exec -T claude-sandbox sh -c 'l=$(cat); grep -qxF "$l" /etc/tinyproxy/filter || printf "%s\n" "$l" >> /etc/tinyproxy/filter'
    Write-Host "allowed: $d"
}

if ($added -eq 0) { Write-Host "No valid domains supplied — nothing added."; exit 1 }

# Reload the proxy filter in place (no dropped sessions). Signal as the tinyproxy user (no CAP_KILL).
docker compose exec -T -u tinyproxy claude-sandbox pkill -HUP tinyproxy
Start-Sleep -Seconds 1

# Safety re-check: the allowlist must STILL deny a known-bad host. If example.com became reachable,
# a bad entry widened the filter to allow-all — fail loudly.
$code = docker compose exec -T claude-sandbox curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -x http://127.0.0.1:8888 http://example.com/ 2>$null
if ($code -eq "403") {
    Write-Host "ok: allowlist still denies example.com (403)."
    Write-Host "proxy reloaded. (Permanent? add these to EXTRA_ALLOWED_DOMAINS in .env)"
} else {
    Write-Host "ERROR: example.com is no longer denied (got '$code') — the allowlist looks too broad."
    Write-Host "Inspect: docker compose exec claude-sandbox cat /etc/tinyproxy/filter"
    exit 1
}
