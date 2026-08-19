# Build + start the Claude Code sandbox on Windows (PowerShell). Run from this folder.
param([switch]$NoStartBrowser)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not (Test-Path ".env")) {
    Write-Host "No .env found. Run setup-windows.cmd first."
    exit 1
}

# This launcher needs Docker on the Windows PATH (Docker Desktop) because it validates and mounts
# Windows-style host paths from .env. If Docker instead lives inside WSL (the ./setup-wsl.sh path),
# build + start from there with ./run.sh — its paths are already WSL paths (/mnt/c/...).
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        Write-Host "Docker isn't on the Windows PATH. If you provisioned Docker inside WSL (./setup-wsl.sh),"
        Write-Host "build + start from a WSL Ubuntu shell instead:  ./run.sh"
        Write-Host "(Once it's running, ./shell.ps1 -Attach works from Windows — it proxies through WSL.)"
    } else {
        Write-Host "Docker not found. Install/start Docker Desktop (WSL2 backend) and try again."
    }
    exit 1
}

# Guarded: native stderr terminates under $ErrorActionPreference='Stop' whatever the redirect, so
# an unguarded probe throws instead of reporting and the branch below never runs (#111, #117, #120).
$dockerRc = 1
try { docker info *> $null; $dockerRc = $LASTEXITCODE } catch { $dockerRc = 1 }
if ($dockerRc -ne 0) {
    Write-Host "Docker isn't running. Start Docker Desktop (WSL2 backend) and try again."
    exit 1
}

# Guard every mounted host dir so a typo in .env can't expose your whole profile/credentials.
# WORK_DIR -> /workspace/work and PERSONAL_DIR -> /workspace/personal; WORKSPACE_DIR (the /workspace
# root) is optional and defaults to an inert umbrella volume. PERSONAL_DIR is also where skill repos
# are cloned (skills-setup) — see compose.
# (PERSONAL_DIR/WORK_DIR were formerly WS_DIR/PROJECTS_DIR; the old names still work below.)
$ic = [System.StringComparison]::OrdinalIgnoreCase
function Norm($p) { return $p.TrimEnd('\','/') }   # canonical compare form
try { $homeResolved = (Resolve-Path -LiteralPath $HOME -ErrorAction Stop).Path } catch { $homeResolved = $HOME }
$home0 = Norm $homeResolved
$badDirs = @("$home0\.ssh","$home0\.aws","$home0\.gnupg","$home0\.config","$home0\.kube",
             "$home0\.docker","$home0\.gcloud","$home0\.azure") | ForEach-Object { Norm $_ }

function Read-DotEnv([string]$Key) {
    $lines = @(Select-String -Path .env -Pattern "^\s*$Key=" | Where-Object { $_.Line -notmatch '^\s*#' })
    if ($lines.Count -gt 1) { Write-Host "Multiple $Key entries in .env — keep one."; exit 1 }
    if ($lines.Count -eq 0) { return '' }
    $v = $lines[0].Line -replace "^\s*$Key=", ''
    return ($v.Trim() -replace '^"(.*)"$', '$1' -replace "^'(.*)'`$", '$1')
}

# A configured SSO region is the explicit opt-in for sandbox-private AWS state as well as egress.
# Keep the base stack unchanged otherwise; naming both files is required once -f is used.
$composeFiles = @()
$awsSsoRegions = Read-DotEnv 'AWS_SSO_REGIONS'
if (-not [string]::IsNullOrWhiteSpace($awsSsoRegions)) {
    $composeFiles = @('-f', 'docker-compose.yml', '-f', 'docker-compose.aws.yml')
    Write-Host "  AWS SSO enabled -> isolated coding-agent-sandbox-aws volume"
}

function Resolve-Mount([string]$Raw, [string]$Label) {
    try { $abs = (Resolve-Path -LiteralPath $Raw -ErrorAction Stop).Path }
    catch { Write-Host "$Label '$Raw' does not exist."; exit 1 }
    $n = Norm $abs
    $root = Norm ([System.IO.Path]::GetPathRoot($abs))
    if ($n.Equals($home0, $ic) -or $n.Equals($root, $ic)) {
        Write-Host "Refusing to mount '$abs' (your whole home or a drive root) for $Label."; exit 1
    }
    foreach ($b in $badDirs) {
        if ($n.Equals($b, $ic) -or $n.StartsWith("$b\", $ic)) {
            Write-Host "Refusing to mount sensitive path '$abs' for $Label."; exit 1
        }
    }
    if ($home0.StartsWith("$n\", $ic)) { Write-Host "Refusing: $Label '$abs' contains your home dir."; exit 1 }
    return $abs
}

# Mount the exact validated paths (shell env overrides .env in Compose).
# WORKSPACE_DIR (the /workspace root) is optional: blank -> Compose falls back to the inert
# claude-workspace umbrella volume (work + personal mount inside). Only validate when it's set.
$wd = Read-DotEnv 'WORKSPACE_DIR'
if (-not [string]::IsNullOrWhiteSpace($wd)) {
    $env:WORKSPACE_DIR = Resolve-Mount $wd 'WORKSPACE_DIR'
} else {
    Write-Host "  /workspace -> inert umbrella volume (work + personal mount inside; set WORKSPACE_DIR for a real root)"
}
# Read-Compat NEW OLD -> value of NEW, else OLD (with a deprecation notice), else ''.
function Read-Compat([string]$New, [string]$Old) {
    $v = Read-DotEnv $New
    if ([string]::IsNullOrWhiteSpace($v)) {
        $v = Read-DotEnv $Old
        if (-not [string]::IsNullOrWhiteSpace($v)) { Write-Host "  (note: $Old is deprecated — rename it to $New in .env)" }
    }
    return $v
}
$psRaw = Read-Compat 'PERSONAL_DIR' 'WS_DIR'
if (-not [string]::IsNullOrWhiteSpace($psRaw)) {
    $env:PERSONAL_DIR = Resolve-Mount $psRaw 'PERSONAL_DIR'
    Write-Host "  mounting PERSONAL_DIR  -> /workspace/personal  ($env:PERSONAL_DIR)"
}
$wkRaw = Read-Compat 'WORK_DIR' 'PROJECTS_DIR'
if (-not [string]::IsNullOrWhiteSpace($wkRaw)) {
    $env:WORK_DIR = Resolve-Mount $wkRaw 'WORK_DIR'
    Write-Host "  mounting WORK_DIR      -> /workspace/work  ($env:WORK_DIR)"
}

# Build, then gate on a supply-chain scan BEFORE starting, so a known-vulnerable image never
# runs. Set $env:SKIP_TRIVY=1 to bypass (e.g. offline with no scanner DB cached).
Write-Host "Building image..."
# Guarded: native stderr terminates under $ErrorActionPreference='Stop' whatever the redirect, so
# an unguarded probe throws instead of reporting and the branch below never runs (#111, #117, #120).
$buildRc = 1
try { docker compose @composeFiles build; $buildRc = $LASTEXITCODE } catch { $buildRc = 1 }
if ($buildRc -ne 0) { Write-Host "Build failed."; exit 1 }

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
        if ($env:TRIVY_STRICT) {
            # STRICT mode: scan.ps1 exits non-zero on findings AND on operational errors - gate the start.
            Write-Host "STRICT scan failed (see above). Set `$env:SKIP_TRIVY=1 to start anyway, or reduce"
            Write-Host "the surface by bumping the base-image digest in the Dockerfile and rebuilding."
            exit 1
        }
        else {
            # Advisory mode: findings never set a non-zero code (scan.ps1 runs with --exit-code 0), so a
            # failure here is OPERATIONAL (no Trivy, Docker Hub pull/rate-limit/TLS/offline). Don't let
            # that block a first-run setup - warn and continue. run.sh has always done this; run.ps1
            # blocked instead, and even said "STRICT scan failed" when the scan was advisory (#119).
            Write-Host "  (advisory scan could not complete - continuing anyway; set `$env:SKIP_TRIVY=1 to skip it)"
        }
    }
}

# Guarded: native stderr terminates under $ErrorActionPreference='Stop' whatever the redirect, so
# an unguarded probe throws instead of reporting and the branch below never runs (#111, #117, #120).
$upRc = 1
try { docker compose @composeFiles up -d; $upRc = $LASTEXITCODE } catch { $upRc = 1 }
if ($upRc -ne 0) { Write-Host "Start failed."; exit 1 }

$port = (Select-String -Path .env -Pattern '^TTYD_PORT=').Line -replace '^TTYD_PORT=', ''
if ([string]::IsNullOrWhiteSpace($port)) { $port = "7681" }

Write-Host ""
Write-Host "  Claude Code sandbox is running."
Write-Host ""
Write-Host "  1. Open:  http://127.0.0.1:$port"
Write-Host "  2. Log in with the TTYD_USER / TTYD_PASS from your .env"
Write-Host "  3. In the terminal:  claude  ->  /login  ->  paste the code from your browser"
Write-Host ""
Write-Host "  Local terminal:  ./shell.ps1       Attach to browser session:  ./shell.ps1 -Attach"
Write-Host "  Stop with:  docker compose down     Logs:  docker compose logs -f"

if (-not $NoStartBrowser) {
    Start-Process "http://127.0.0.1:$port" | Out-Null
}
