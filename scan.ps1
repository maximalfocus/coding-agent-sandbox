# Supply-chain gate (Windows): scan the built sandbox image for known-vulnerable packages with
# Trivy. Mirrors scan.sh. Called by run.ps1 before starting the container; can also run standalone.
#   powershell -ExecutionPolicy Bypass -File .\scan.ps1
param([string]$Image = "coding-agent-sandbox:latest")

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

# Only FIXED vulns gate the build (--ignore-unfixed): those are actionable. Tune via $env:TRIVY_SEVERITY.
$sev = if ($env:TRIVY_SEVERITY) { $env:TRIVY_SEVERITY } else { "HIGH,CRITICAL" }
$trivyImage = if ($env:TRIVY_IMAGE) { $env:TRIVY_IMAGE } else { "aquasec/trivy:latest" }
$common = @("image", "--severity", $sev, "--ignore-unfixed", "--exit-code", "1", "--no-progress")

Write-Host "Scanning $Image for $sev vulnerabilities (fixed only)..."

docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Image '$Image' not found locally. Build it first (start-sandbox.cmd or 'docker compose build')."
    exit 1
}

# Prefer a local trivy binary (winget install AquaSecurity.Trivy); else use the official container.
if (Get-Command trivy -ErrorAction SilentlyContinue) {
    & trivy @common $Image
    exit $LASTEXITCODE
}

Write-Host "  (no local 'trivy' — using $trivyImage via docker)"
# Hand Trivy the image as a tarball (no Docker socket mount). Mount the temp DIR (a single-file
# bind mount is unreliable on Windows + Docker Desktop), then point --input at the file inside it.
$tarDir = Join-Path $env:TEMP ("sandbox-scan-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tarDir | Out-Null
$code = 0
try {
    $tar = Join-Path $tarDir "image.tar"
    docker save $Image -o $tar
    if ($LASTEXITCODE -ne 0) { throw "docker save failed for '$Image'." }
    $mount = ($tarDir -replace '\\', '/')
    docker run --rm -v "${mount}:/work:ro" -v claude-sandbox-trivy-cache:/root/.cache/trivy `
        $trivyImage @common --input /work/image.tar
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tarDir -ErrorAction SilentlyContinue
}
exit $code
