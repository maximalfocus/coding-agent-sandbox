# First-run setup for Windows. Run from this folder:
#   powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 -InstallPrereqs
param(
    [string]$WorkspaceDir,
    [string]$PersonalDir,
    [string]$WorkDir,
    [string[]]$SkillRepos,
    [string]$Password,
    [int]$Port = 7681,
    [switch]$InstallPrereqs,
    [switch]$NoStartBrowser
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Convert-ToComposePath([string]$Path) {
    $fullPath = (Resolve-Path -Path $Path -ErrorAction Stop).Path
    return ($fullPath -replace '\\', '/')
}

function Get-ComposeDir([string]$Path) {
    # Create the directory if needed and return its forward-slash absolute path for Compose.
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        throw "'$Path' exists but is a file. Move it or choose a different directory."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return (Convert-ToComposePath $Path)
}

function New-TerminalPassword([int]$Length = 20) {
    $chars = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".ToCharArray()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] ($Length)
        $rng.GetBytes($bytes)
        return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    }
    finally {
        $rng.Dispose()
    }
}

function Get-DotEnvValue([string]$Path, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $pattern = "^\s*$([Regex]::Escape($Key))\s*="
    $line = Get-Content -LiteralPath $Path |
        Where-Object { $_ -match $pattern -and $_ -notmatch '^\s*#' } |
        Select-Object -Last 1
    if ($null -eq $line) { return $null }
    $value = $line -replace $pattern, ""
    $value = $value.Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
}

function Format-DotEnvValue([string]$Value) {
    if ($Value -match '\s') {
        return '"' + ($Value.Replace('"', '\"')) + '"'
    }
    return $Value
}

function Set-DotEnvValue([string]$Path, [string]$Key, [string]$Value) {
    $newLine = "$Key=$(Format-DotEnvValue $Value)"
    $content = @()
    if (Test-Path -LiteralPath $Path) {
        $content = @(Get-Content -LiteralPath $Path)
    }

    $pattern = "^\s*$([Regex]::Escape($Key))\s*="
    $updated = $false
    $nextContent = foreach ($line in $content) {
        if (-not $updated -and $line -match $pattern -and $line -notmatch '^\s*#') {
            $updated = $true
            $newLine
        }
        else {
            $line
        }
    }

    if (-not $updated) {
        $nextContent += $newLine
    }

    # Write UTF-8 WITHOUT a BOM and with LF endings. Windows PowerShell 5.1's
    # `Set-Content -Encoding UTF8` emits a BOM (which can corrupt the first .env key for
    # `docker compose`) and CRLF (a trailing \r would break mount paths/values).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (($nextContent -join "`n") + "`n"), $utf8NoBom)
}

function Install-WingetPackage([string]$Name, [string]$Id) {
    if (-not (Test-Command "winget")) {
        throw "winget is not available. Install App Installer from Microsoft Store, then rerun this script."
    }

    Write-Step "Installing $Name"
    & winget install --id $Id --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget could not install $Name. Install it manually, then rerun this script."
    }
}

function Test-WslReady {
    if (-not (Test-Command "wsl")) { return $false }
    & wsl --status *> $null
    return ($LASTEXITCODE -eq 0)
}

function Ensure-WslReady {
    if (Test-WslReady) { return }

    if (-not $InstallPrereqs) {
        Write-Host "WSL2 is not ready. Docker Desktop may ask you to finish WSL2 setup." -ForegroundColor Yellow
        return
    }

    if (-not (Test-Command "wsl")) {
        throw "wsl.exe is not available. Update Windows, then rerun this script."
    }

    Write-Step "Enabling WSL2"
    & wsl --install --no-distribution
    if ($LASTEXITCODE -eq 0) {
        Write-Host "WSL2 setup was started. Restart Windows if prompted, then run this script again."
        exit 0
    }

    throw "WSL2 could not be enabled automatically. Run PowerShell as Administrator, run 'wsl --install --no-distribution', restart if prompted, then rerun this script."
}

function Add-DockerToPathForThisSession {
    $dockerBin = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin"
    if (Test-Path -LiteralPath $dockerBin) {
        $env:PATH = "$dockerBin;$env:PATH"
    }
}

function Add-GitToPathForThisSession {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += (Join-Path $env:ProgramFiles "Git\cmd")
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $candidates += (Join-Path $programFilesX86 "Git\cmd")
    }

    foreach ($gitBin in $candidates) {
        if (Test-Path -LiteralPath $gitBin) {
            $env:PATH = "$gitBin;$env:PATH"
            return
        }
    }
}

function Test-DockerRunning {
    if (-not (Test-Command "docker")) { return $false }
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Start-DockerDesktop {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"),
        (Join-Path $env:LOCALAPPDATA "Docker\Docker Desktop.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            Start-Process -FilePath $candidate | Out-Null
            return $true
        }
    }

    try {
        Start-Process -FilePath "Docker Desktop" | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Wait-ForDocker {
    if (Test-DockerRunning) { return }

    Write-Step "Starting Docker Desktop"
    if (-not (Start-DockerDesktop)) {
        throw "Docker Desktop is installed but could not be started automatically. Open Docker Desktop, wait until it is running, then rerun this script."
    }

    Write-Host "Waiting for Docker to become ready" -NoNewline
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 2
        if (Test-DockerRunning) {
            Write-Host ""
            return
        }
        Write-Host "." -NoNewline
    }
    Write-Host ""
    throw "Docker did not become ready. If Docker Desktop asked for WSL2 setup or a restart, finish that step and rerun this script."
}

Write-Step "Checking prerequisites"
Ensure-WslReady

if (-not (Test-Command "docker")) {
    if ($InstallPrereqs) {
        Install-WingetPackage "Docker Desktop" "Docker.DockerDesktop"
        Add-DockerToPathForThisSession
    }
    else {
        throw "Docker is not installed. Install Docker Desktop, or rerun with -InstallPrereqs."
    }
}
else {
    Add-DockerToPathForThisSession
}

Add-GitToPathForThisSession
if (-not (Test-Command "git") -and $InstallPrereqs) {
    Install-WingetPackage "Git" "Git.Git"
    Add-GitToPathForThisSession
}

if (-not (Test-Command "docker")) {
    throw "Docker was installed, but this PowerShell session cannot see it yet. Close PowerShell, open it again, and rerun this script."
}

& docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose is not available. Update Docker Desktop, then rerun this script."
}

$envPath = Join-Path $PSScriptRoot ".env"
$envExamplePath = Join-Path $PSScriptRoot ".env.example"
if (-not (Test-Path -LiteralPath $envPath)) {
    if (-not (Test-Path -LiteralPath $envExamplePath)) {
        throw ".env.example is missing; cannot create .env."
    }
    Copy-Item -LiteralPath $envExamplePath -Destination $envPath
}

# WORKSPACE_DIR is OPTIONAL (the /workspace root). Blank -> Compose uses an inert umbrella volume
# and only PERSONAL_DIR/WORK_DIR mount inside it. Set it only to expose a real /workspace root.
$existingWorkspace = Get-DotEnvValue $envPath "WORKSPACE_DIR"
$workspaceFull = ""
if (-not [string]::IsNullOrWhiteSpace($WorkspaceDir)) {
    $workspaceFull = Get-ComposeDir $WorkspaceDir
}
elseif (-not [string]::IsNullOrWhiteSpace($existingWorkspace) -and $existingWorkspace -ne "./workspace") {
    $workspaceFull = $existingWorkspace
    Write-Step "Using existing WORKSPACE_DIR: $workspaceFull"
}

# PERSONAL_DIR -> /workspace/personal (also where skills-setup clones skill repos) and
# WORK_DIR -> /workspace/work are the two host trees the sandbox edits. Use the flag, else an
# existing .env value, else prompt with a default under the user profile.
$existingPersonal = Get-DotEnvValue $envPath "PERSONAL_DIR"
if ([string]::IsNullOrWhiteSpace($PersonalDir)) {
    if (-not [string]::IsNullOrWhiteSpace($existingPersonal)) {
        $PersonalDir = $existingPersonal
    }
    else {
        $defaultPersonal = Join-Path $env:USERPROFILE "personal"
        $answer = Read-Host "Host folder to mount at /workspace/personal (skills clone here) [$defaultPersonal]"
        $PersonalDir = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultPersonal } else { $answer }
    }
}
$existingWork = Get-DotEnvValue $envPath "WORK_DIR"
if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    if (-not [string]::IsNullOrWhiteSpace($existingWork)) {
        $WorkDir = $existingWork
    }
    else {
        $defaultWork = Join-Path $env:USERPROFILE "work"
        $answer = Read-Host "Host folder to mount at /workspace/work [$defaultWork]"
        $WorkDir = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultWork } else { $answer }
    }
}
$personalFull = Get-ComposeDir $PersonalDir
$workFull = Get-ComposeDir $WorkDir

# SKILL_REPOS (optional): space-separated HTTPS git URLs cloned into /workspace/personal by
# skills-setup. Use the flag if given, else keep any existing value.
$existingSkillRepos = Get-DotEnvValue $envPath "SKILL_REPOS"
$skillReposValue = $existingSkillRepos
if ($SkillRepos -and $SkillRepos.Count -gt 0) {
    $skillReposValue = ($SkillRepos -join " ")
}

$existingPassword = Get-DotEnvValue $envPath "TTYD_PASS"
if ([string]::IsNullOrWhiteSpace($Password)) {
    if (-not [string]::IsNullOrWhiteSpace($existingPassword) -and
        $existingPassword -ne "please-change-me" -and
        $existingPassword -ne "changeme") {
        $Password = $existingPassword
    }
    else {
        $Password = New-TerminalPassword
    }
}

Write-Step "Writing .env"
Set-DotEnvValue $envPath "WORKSPACE_DIR" $workspaceFull
Set-DotEnvValue $envPath "PERSONAL_DIR" $personalFull
Set-DotEnvValue $envPath "WORK_DIR" $workFull
Set-DotEnvValue $envPath "TTYD_USER" "coder"
Set-DotEnvValue $envPath "TTYD_PASS" $Password
Set-DotEnvValue $envPath "TTYD_PORT" ([string]$Port)
if (-not [string]::IsNullOrWhiteSpace($skillReposValue)) {
    Set-DotEnvValue $envPath "SKILL_REPOS" $skillReposValue
}

Wait-ForDocker

Write-Step "Building and starting the sandbox"
$runArgs = @()
if ($NoStartBrowser) {
    $runArgs += "-NoStartBrowser"
}

& (Join-Path $PSScriptRoot "run.ps1") @runArgs
if ($LASTEXITCODE -ne 0) {
    throw "run.ps1 failed."
}

$url = "http://127.0.0.1:$Port"
Write-Host ""
Write-Host "Ready."
Write-Host "Open:     $url"
Write-Host "User:     coder"
Write-Host "Password: $Password"
Write-Host "personal: $personalFull -> /workspace/personal"
Write-Host "work:     $workFull -> /workspace/work"
Write-Host ""
Write-Host "Inside the browser terminal, run:"
Write-Host "  claude"
Write-Host "  /login"
Write-Host ""
Write-Host "For cross-vendor peer review with Codex (your ChatGPT/OpenAI subscription):"
Write-Host "  codex-login.cmd     (one-time sign-in; then type 'codex' in the terminal)"
Write-Host ""
Write-Host "Next time, start with:  start-sandbox.cmd"
