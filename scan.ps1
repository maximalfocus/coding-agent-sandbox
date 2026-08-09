# Supply-chain scan (Windows). Mirrors scan.sh: ADVISORY by default (prints findings, does not
# block the sandbox from starting), because this full Debian + Node image plus third-party CLIs
# carries fixed CVEs you can't patch yourself. Set $env:TRIVY_STRICT=1 to gate on findings.
#   powershell -ExecutionPolicy Bypass -File .\scan.ps1
param([string]$Image = "coding-agent-sandbox:latest")

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$sev = if ($env:TRIVY_SEVERITY) { $env:TRIVY_SEVERITY } else { "HIGH,CRITICAL" }
$trivyImage = if ($env:TRIVY_IMAGE) { $env:TRIVY_IMAGE } else { "aquasec/trivy:latest" }
$gate = if ($env:TRIVY_STRICT) { 1 } else { 0 }
$common = @("image", "--severity", $sev, "--ignore-unfixed", "--no-progress", "--exit-code", "$gate")

$mode = if ($gate -eq 1) { "STRICT - blocks on findings" } else { "advisory - report only (set TRIVY_STRICT=1 to block)" }
Write-Host "Scanning $Image for $sev (fixed only; $mode)..."

docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Image '$Image' not found locally. Build it first (start-sandbox.cmd or 'docker compose build')."
    exit 1
}

$report = New-TemporaryFile
$rc = 0
if (Get-Command trivy -ErrorAction SilentlyContinue) {
    & trivy @common $Image *> $report.FullName
    $rc = $LASTEXITCODE
}
else {
    Write-Host "  (no local 'trivy' - using $trivyImage via docker)"
    $tarDir = Join-Path $env:TEMP ("sandbox-scan-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tarDir | Out-Null
    try {
        $tar = Join-Path $tarDir "image.tar"
        docker save $Image -o $tar
        if ($LASTEXITCODE -ne 0) { throw "docker save failed for '$Image'." }
        $mount = ($tarDir -replace '\\', '/')
        docker run --rm -v "${mount}:/work:ro" -v coding-agent-sandbox-trivy-cache:/root/.cache/trivy `
            $trivyImage @common --input /work/image.tar *> $report.FullName
        $rc = $LASTEXITCODE
    }
    finally {
        Remove-Item -Recurse -Force -LiteralPath $tarDir -ErrorAction SilentlyContinue
    }
}

if ($env:TRIVY_SUMMARY) {
    $hits = Select-String -Path $report.FullName -Pattern ("Total:|^" + [Regex]::Escape($Image))
    if ($hits) { $hits.Line } else { Write-Host "  (no summary lines - run scan.ps1 for detail)" }
}
else {
    Get-Content $report.FullName
}
Remove-Item -LiteralPath $report.FullName -ErrorAction SilentlyContinue

if ($gate -eq 1 -and $rc -ne 0) { Write-Host "STRICT scan: fixed $sev vulnerabilities present (see above)." }
exit $rc
