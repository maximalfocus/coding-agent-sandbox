# Build + start the Claude Code sandbox on Windows (PowerShell). Run from this folder.
param([switch]$NoStartBrowser)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not (Test-Path ".env")) {
    Write-Host "No .env found. Run setup-windows.cmd first."
    exit 1
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker isn't running. Start Docker Desktop (WSL2 backend) and try again."
    exit 1
}

# Guard the mounted workspace so a typo can't expose your whole profile/credentials.
# Parse like run.sh: skip comments/whitespace, reject duplicate keys, strip quotes.
$wdLines = @(Select-String -Path .env -Pattern '^\s*WORKSPACE_DIR=' |
             Where-Object { $_.Line -notmatch '^\s*#' })
if ($wdLines.Count -gt 1) { Write-Host "Multiple WORKSPACE_DIR entries in .env — keep one."; exit 1 }
$wd = if ($wdLines.Count -eq 1) { $wdLines[0].Line -replace '^\s*WORKSPACE_DIR=', '' } else { '' }
$wd = $wd.Trim() -replace '^"(.*)"$', '$1' -replace "^'(.*)'`$", '$1'
if ([string]::IsNullOrWhiteSpace($wd)) { $wd = "./workspace" }
try { $wdAbs = (Resolve-Path -LiteralPath $wd -ErrorAction Stop).Path }
catch { Write-Host "WORKSPACE_DIR '$wd' does not exist."; exit 1 }

$ic = [System.StringComparison]::OrdinalIgnoreCase
function Norm($p) { return $p.TrimEnd('\','/') }   # canonical compare form
$wdNorm = Norm $wdAbs
# Reject the drive/UNC root explicitly (Norm('D:\')='D:' must match Norm(root)).
$root = [System.IO.Path]::GetPathRoot($wdAbs)
try { $homeResolved = (Resolve-Path -LiteralPath $HOME -ErrorAction Stop).Path } catch { $homeResolved = $HOME }
$home0 = Norm $homeResolved
$bad = @($home0, (Norm $root),
         "$home0\.ssh","$home0\.aws","$home0\.gnupg","$home0\.config","$home0\.kube",
         "$home0\.docker","$home0\.gcloud","$home0\.azure") | ForEach-Object { Norm $_ }
foreach ($b in $bad) {
    if ($wdNorm.Equals($b, $ic) -or $wdNorm.StartsWith("$b\", $ic)) {
        Write-Host "Refusing to mount sensitive/broad WORKSPACE_DIR '$wdAbs'. Point it at a project dir."; exit 1
    }
}
if ($home0.StartsWith("$wdNorm\", $ic)) { Write-Host "Refusing: WORKSPACE_DIR contains your home dir."; exit 1 }

# Mount the exact validated path (shell env overrides .env in Compose).
$env:WORKSPACE_DIR = $wdAbs

# Build, then gate on a supply-chain scan BEFORE starting, so a known-vulnerable image never
# runs. Set $env:SKIP_TRIVY=1 to bypass (e.g. offline with no scanner DB cached).
Write-Host "Building image..."
docker compose build
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed."; exit 1 }

if ($env:SKIP_TRIVY) {
    Write-Host "  (SKIP_TRIVY set — skipping image vulnerability scan)"
}
else {
    $env:TRIVY_SUMMARY = "1"
    & (Join-Path $PSScriptRoot "scan.ps1")
    $scanRc = $LASTEXITCODE
    Remove-Item Env:\TRIVY_SUMMARY -ErrorAction SilentlyContinue
    if ($scanRc -ne 0) {
        Write-Host ""
        Write-Host "STRICT scan failed (see above). Set `$env:SKIP_TRIVY=1 to start anyway, or reduce"
        Write-Host "the surface by bumping the base-image digest in the Dockerfile and rebuilding."
        exit 1
    }
}

docker compose up -d
if ($LASTEXITCODE -ne 0) { Write-Host "Start failed."; exit 1 }

$port = (Select-String -Path .env -Pattern '^TTYD_PORT=').Line -replace '^TTYD_PORT=', ''
if ([string]::IsNullOrWhiteSpace($port)) { $port = "7681" }

Write-Host ""
Write-Host "  Claude Code sandbox is running."
Write-Host ""
Write-Host "  1. Open:  http://127.0.0.1:$port"
Write-Host "  2. Log in with the TTYD_USER / TTYD_PASS from your .env"
Write-Host "  3. In the terminal:  claude  ->  /login  ->  paste the code from your browser"
Write-Host ""
Write-Host "  Stop with:  docker compose down     Logs:  docker compose logs -f"

if (-not $NoStartBrowser) {
    Start-Process "http://127.0.0.1:$port" | Out-Null
}
