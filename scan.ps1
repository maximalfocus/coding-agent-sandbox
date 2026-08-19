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

# Guarded: native stderr terminates under $ErrorActionPreference='Stop' whatever the redirect, so
# an unguarded probe throws instead of reporting and the branch below never runs (#111, #117, #120).
$inspectRc = 1
try { docker image inspect $Image *> $null; $inspectRc = $LASTEXITCODE } catch { $inspectRc = 1 }
if ($inspectRc -ne 0) {
    Write-Host "Image '$Image' not found locally. Build it first (start-sandbox.cmd or 'docker compose build')."
    exit 1
}

$report = New-TemporaryFile
$rc = 0
if (Get-Command trivy -ErrorAction SilentlyContinue) {
    # A scanner reports progress and INFO on **stderr** even on a completely successful run, and under
    # `$ErrorActionPreference = "Stop"` Windows PowerShell 5.1 turns native stderr into a TERMINATING
    # NativeCommandError -- redirection does not prevent it. That aborted an *advisory* scan, and with
    # it run.ps1 and setup-windows.ps1, on a fresh Windows + Docker Desktop host (issue #119). Relaxing
    # the preference for the duration of each scanner call is what makes stderr ordinary output again;
    # the exit code, which is the scanner's actual verdict, is then read normally and STRICT still gates
    # on it. Each call stays written inline rather than behind a helper so scripts/native-probe-gate.ps1
    # can still see it (#120), which is why the pattern repeats.
    $rc = 1
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & trivy @common $Image *> $report.FullName
        $rc = $LASTEXITCODE
    }
    catch { $rc = 1 }
    finally { $ErrorActionPreference = $prevEap }
}
else {
    Write-Host "  (no local 'trivy' - using $trivyImage via docker)"
    $tarDir = Join-Path $env:TEMP ("sandbox-scan-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tarDir | Out-Null
    try {
        $tar = Join-Path $tarDir "image.tar"
        # Guarded: the enclosing try has only a finally, which reruns cleanup and RETHROWS, so this
        # was never protected despite sitting inside a try (#120). The preference is relaxed for the
        # same reason as the scanner call below -- `docker save` prints progress to stderr (#119).
        $saveRc = 1
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            docker save $Image -o $tar
            $saveRc = $LASTEXITCODE
        }
        catch { $saveRc = 1 }
        finally { $ErrorActionPreference = $prevEap }
        if ($saveRc -ne 0) { throw "docker save failed for '$Image'." }
        $mount = ($tarDir -replace '\\', '/')
        # The scanner container: the site that actually broke the documented Windows journey (#119).
        # Its `INFO [vulndb] Need to update DB` on a healthy run was enough to abort the caller.
        $rc = 1
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            docker run --rm -v "${mount}:/work:ro" -v coding-agent-sandbox-trivy-cache:/root/.cache/trivy `
                $trivyImage @common --input /work/image.tar *> $report.FullName
            $rc = $LASTEXITCODE
        }
        catch { $rc = 1 }
        finally { $ErrorActionPreference = $prevEap }
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
