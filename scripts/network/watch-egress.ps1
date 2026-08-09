# Watch the sandbox's egress audit trail and ALERT the moment a NEW host is refused (403/filtered).
# Mirror of watch-egress.sh. For each new blocked host: a Windows toast + a console beep.
#
#   ./scripts/network/watch-egress.ps1              # interactive: notify + prompt allow/skip per host
#   ./scripts/network/watch-egress.ps1 -NotifyOnly  # only alert (toast + beep), never act
#   ./scripts/network/watch-egress.ps1 -Auto        # AUTO-ASSESS: classify by risk and act automatically
#   ./scripts/network/watch-egress.ps1 -Auto -Llm   # same, but route gray-zone hosts to headless `claude -p /assess`
#
# -Auto tiers (mirrors the /assess skill):
#   ALLOW  : known-safe first-party read-only / cloud APIs -> allow-domain.ps1 + persist + notify
#   REJECT : trackers / ads / metadata / IP literals       -> leave blocked + notify
#   GRAY   : everything else (incl. storage/drive)          -> notify "needs review"
#            (with -Llm: hand to `claude -p "/assess <host>"`, defaults to reject-on-uncertainty)
#
# Allowing is IMMEDIATE; -Auto also persists to EXTRA_ALLOWED_DOMAINS in .env. Ctrl-C to stop.
param([switch]$NotifyOnly, [switch]$Auto, [switch]$Llm)
$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot '../..')

$SVC = "claude-sandbox"
$LOG = "/var/log/tinyproxy/tinyproxy.log"
$Mode = if ($Auto) { "auto" } elseif ($NotifyOnly) { "notify" } else { "interactive" }

$running = docker compose ps --status running --format '{{.Name}}' 2>$null
if ([string]::IsNullOrWhiteSpace($running)) {
    Write-Host "Sandbox isn't running. Start it first:  ./run.ps1"; exit 1
}

function Show-Alert([string]$title, [string]$message) {
    try { [console]::beep(800, 300) } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Warning
        $ni.Visible = $true
        $ni.ShowBalloonTip(8000, $title, $message, [System.Windows.Forms.ToolTipIcon]::Warning)
        Start-Sleep -Milliseconds 250
    } catch {}
}

# Risk verdict: returns 'allow' | 'reject' | 'gray'. Conservative — unknown => gray.
function Get-Verdict([string]$h) {
    if ($h -match '^[0-9]+(\.[0-9]+){3}$') { return 'reject' }   # IP literal incl. metadata 169.254.x
    $reject = @(
        '(^|\.)doubleclick\.net$', '\.googlesyndication\.com$', '\.googleadservices\.com$', '^googleads\.',
        '\.google-analytics\.com$', '\.analytics\.google\.com$', '\.googletagmanager\.com$', '\.umami\.is$',
        '^mtalk\.google\.com$', '^metadata\.google\.internal$', '\.metadata\.goog$')
    foreach ($p in $reject) { if ($h -match $p) { return 'reject' } }
    $gray = @('(^|\.)storage\.googleapis\.com$', '(^|\.)drive\.google\.com$')
    foreach ($p in $gray) { if ($h -match $p) { return 'gray' } }
    $allow = @(
        '\.googleapis\.com$', '\.pkg\.dev$', '(^|\.)gstatic\.com$', '(^|\.)ggpht\.com$',
        '(^|\.)googlevideo\.com$', '(^|\.)ytimg\.com$', '^dl\.google\.com$', '^accounts\.google\.com$',
        '\.developers\.google\.com$', '^ai\.google\.dev$', '^pypi\.org$', '(^|\.)pythonhosted\.org$',
        '(^|\.)pypa\.io$', '(^|\.)crates\.io$', '^static\.rust-lang\.org$', '^rustup\.rs$',
        '^cdn\.playwright\.dev$', '^astral\.sh$')
    foreach ($p in $allow) { if ($h -match $p) { return 'allow' } }
    return 'gray'
}

function Add-Persist([string]$h) {
    $cur = Select-String -Path .env -Pattern '^EXTRA_ALLOWED_DOMAINS='
    if ($cur -and ($cur.Line -split '[=,]') -contains $h) { return }
    (Get-Content .env) -replace '^(EXTRA_ALLOWED_DOMAINS=.*)$', "`$1,$h" | Set-Content .env
}

function Invoke-Allow([string]$h) {
    & "$PSScriptRoot/allow-domain.ps1" $h *> $null
    if ($LASTEXITCODE -eq 0) {
        Add-Persist $h
        Write-Host "       AUTO-ALLOWED $h (persisted)" -ForegroundColor Green
        Show-Alert "Sandbox auto-allowed" "$h - known-safe, allowed + persisted."
    } else {
        Write-Host "       allow-domain failed for $h (left blocked)"
        Show-Alert "Sandbox allow failed" "$h - could not allow; left blocked."
    }
}

Write-Host "Watching sandbox egress for refused hosts... mode=$Mode$(if($Llm){' llm=1'}) (Ctrl-C to stop)"
$seen = @{}

docker compose exec -T $SVC tail -F -n0 $LOG 2>$null | ForEach-Object {
    if ($_ -notmatch 'refused on filtered') { return }
    if ($_ -notmatch 'filtered domain "([^"]+)"') { return }
    $h = $matches[1]
    if ($h -eq 'example.com') { return }   # allow-domain.ps1 safety-canary probe — never a real host
    if ($seen.ContainsKey($h)) { return }
    $seen[$h] = $true
    Write-Host ""; Write-Host ("  [{0}] BLOCKED: {1}" -f (Get-Date).ToString("HH:mm:ss"), $h) -ForegroundColor Yellow

    switch ($Mode) {
        'notify' { Show-Alert "Sandbox blocked egress" "$h - blocked. Evaluate & allow if trusted." }
        'interactive' {
            Show-Alert "Sandbox blocked egress" "$h - blocked. Evaluate & allow if trusted."
            $ans = Read-Host "       Allow $h now? [y = allow / Enter = skip]"
            if ($ans -eq 'y' -or $ans -eq 'Y') { Invoke-Allow $h } else { Write-Host "       left blocked." }
        }
        'auto' {
            switch (Get-Verdict $h) {
                'allow'  { Invoke-Allow $h }
                'reject' {
                    Write-Host "       AUTO-REJECTED $h (tracker/metadata - left blocked)" -ForegroundColor DarkYellow
                    Show-Alert "Sandbox auto-rejected" "$h - tracker/metadata, left blocked."
                }
                'gray' {
                    if ($Llm) {
                        Write-Host "       gray zone -> headless /assess $h ..."
                        Show-Alert "Sandbox assessing" "$h - running /assess..."
                        claude -p "/assess $h" *> $null
                        Write-Host "       /assess finished for $h (see audit.sh / .env)"
                    } else {
                        Write-Host "       NEEDS REVIEW $h - run: /assess $h  (or ./scripts/network/allow-domain.ps1 $h)"
                        Show-Alert "Sandbox: needs your review" "$h - not auto-classified. Run /assess."
                    }
                }
            }
        }
    }
}
