# Regression coverage for issue #46's PowerShell egress-watcher policy.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'scripts/network/watch-egress-policy.ps1')

function Assert-Verdict([string]$Expected, [string]$HostName) {
    $Actual = Get-EgressVerdict $HostName
    if ($Actual -ne $Expected) {
        throw "$HostName`: expected $Expected, got $Actual"
    }
}

Assert-Verdict review artifactregistry.googleapis.com
Assert-Verdict review arbitrary-tenant.googleapis.com
Assert-Verdict review us-central1-docker.pkg.dev
Assert-Verdict review storage.googleapis.com
Assert-Verdict review bucket.storage.googleapis.com
Assert-Verdict review drive.google.com
Assert-Verdict allow gstatic.com
Assert-Verdict allow cdn.playwright.dev
Assert-Verdict allow pypi.org
Assert-Verdict reject tracker.doubleclick.net
Assert-Verdict reject 169.254.169.254
Assert-Verdict gray uploads.example.com

$Watcher = Get-Content (Join-Path $Root 'scripts/network/watch-egress.ps1') -Raw
if ($Watcher -notmatch [regex]::Escape(". (Join-Path `$PSScriptRoot 'watch-egress-policy.ps1')")) {
    throw 'PowerShell watcher does not load its policy helper'
}
if ($Watcher -notmatch 'switch \(Get-EgressVerdict \$h\)') {
    throw 'PowerShell watcher does not use Get-EgressVerdict'
}
if ($Watcher -notmatch "(?m)^\s*'review'\s*\{") {
    throw 'PowerShell watcher has no review-only branch'
}
$ReviewMatch = [regex]::Match($Watcher, "(?ms)^\s*'review'\s*\{(?<body>.*?)^\s*\}\s*^\s*'gray'")
if (-not $ReviewMatch.Success) {
    throw 'PowerShell watcher review branch cannot be isolated from the gray branch'
}
$ReviewBranch = $ReviewMatch.Groups['body'].Value
if ($ReviewBranch -notmatch 'left blocked') {
    throw 'PowerShell review branch does not explicitly leave the host blocked'
}
if ($ReviewBranch -match 'Invoke-Allow|Add-Persist|claude\s+-p') {
    throw 'PowerShell review branch can invoke unattended allow, persistence, or LLM assessment'
}

Write-Host 'PASS: PowerShell watcher keeps broad Google API and package-registry namespaces human-review-only'
