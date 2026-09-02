# Shared Docker resolution, guard, and custody disclosure for the host-side sign-in commands
# (issue #151, CAS-R034).
#
# Dot-sourced, never run on its own. The POSIX twin is scripts/auth/auth-common.sh and the two must
# stay at parity: same guards, same refusal wording, same disclosure, read from the same table.
#
# The custody tier is NOT restated here. It is read from docs/credential-custody.md, which
# scripts/check-credential-custody.sh proves against the shipped Compose wiring, so a command cannot
# claim a tier the configuration does not implement.

$script:AuthRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:AuthCustodyDoc = Join-Path $script:AuthRoot 'docs/credential-custody.md'
$script:AuthService = 'claude-sandbox'
$script:DockerExe = $null
$script:DockerLead = @()

function Write-AuthRefusal {
    param([string]$Reason, [string[]]$Detail = @())
    Write-Host "REFUSING: $Reason"
    foreach ($line in $Detail) { Write-Host "  $line" }
}

# Resolve how to reach the Docker CLI:
#   'docker' / @()                            -> Docker Desktop (the CLI is on the Windows PATH)
#   'wsl'    / @('-d','Ubuntu','--','docker') -> dockerd lives in a WSL2 distro (./setup-wsl.sh)
# Set $env:SANDBOX_WSL_DISTRO when the daemon is not in the default distro. Returns $true/$false.
function Resolve-AuthDocker {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $script:DockerExe = 'docker'; $script:DockerLead = @()
        return $true
    }
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        $distro = $env:SANDBOX_WSL_DISTRO
        # [string[]] keeps this an ARRAY: PowerShell would otherwise unwrap a 1-element @('--') to
        # the scalar '--', turning the later '+' into string concat.
        [string[]]$pre = if ([string]::IsNullOrWhiteSpace($distro)) { @('--') } else { @('-d', $distro, '--') }
        # Guarded because a probe must be able to report "not available". wsl.exe writes to stderr
        # when the subsystem is absent, and under $ErrorActionPreference='Stop' PowerShell turns
        # native stderr into a TERMINATING NativeCommandError regardless of the redirect (issue #111).
        $probeExit = 1
        try { & wsl @($pre + @('docker', 'version', '--format', '{{.Server.Version}}')) *> $null; $probeExit = $LASTEXITCODE }
        catch { $probeExit = 1 }
        if ($probeExit -eq 0) {
            $script:DockerExe = 'wsl'; $script:DockerLead = $pre + 'docker'
            return $true
        }
    }
    return $false
}

# Deliberately a SIMPLE function using $args, not an advanced one with
# [Parameter(ValueFromRemainingArguments)]. That attribute gains the common parameters, and
# PowerShell then binds a literal -w/-e/-o as a PARAMETER NAME before treating it as a value
# (issue #115). Measured on Windows PowerShell 5.1.
function Invoke-AuthDocker {
    & $script:DockerExe @($script:DockerLead + $args)
}

# Refuse with an actionable message when no Docker can be reached at all.
function Assert-AuthDocker {
    param([string]$PosixScript)
    if (Resolve-AuthDocker) { return }
    Write-AuthRefusal "Docker was not found." @(
        "Start Docker Desktop, or - if you provisioned Docker inside WSL (./setup-wsl.sh) -",
        "run './scripts/auth/$PosixScript' from a WSL Ubuntu shell instead.")
    exit 1
}

# Get-AuthRow ID -> a hashtable of the row's fields. A missing row is a broken install, not a
# default: without it the operator would not be told where the credential lands.
function Get-AuthRow {
    param([Parameter(Mandatory = $true)][string]$Id)
    if (-not (Test-Path -LiteralPath $script:AuthCustodyDoc)) {
        Write-AuthRefusal "the credential custody table is missing." @("expected: $($script:AuthCustodyDoc)")
        exit 1
    }
    $inBlock = $false
    foreach ($line in [System.IO.File]::ReadAllLines($script:AuthCustodyDoc)) {
        if ($line -eq '```credential-custody') { $inBlock = $true; continue }
        if ($inBlock -and $line.StartsWith('```')) { break }
        if (-not $inBlock) { continue }
        $text = $line.Trim()
        if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }
        $f = $text.Split('|')
        if ($f.Count -ne 9) { continue }
        if ($f[0].Trim() -ne $Id) { continue }
        return @{
            Id = $f[0].Trim(); Tool = $f[1].Trim(); Command = $f[2].Trim(); Gate = $f[3].Trim()
            Volume = $f[4].Trim(); Path = $f[5].Trim(); Tier = $f[6].Trim()
            Isolation = $f[7].Trim(); Note = $f[8].Trim()
        }
    }
    Write-AuthRefusal "no custody row for '$Id' in docs/credential-custody.md." @(
        "A sign-in command must not run without one: the operator would not be told where the credential lands.")
    exit 1
}

# Refuse by name when the sandbox is not up, rather than letting the exec fail later. Matched by
# name (not the compose project) so it works from any directory, through Desktop or WSL.
function Assert-AuthStack {
    $running = $null
    try {
        $running = Invoke-AuthDocker ps --filter "name=^$($script:AuthService)$" --filter 'status=running' --format '{{.Names}}'
    } catch { $running = $null }
    if ([string]::IsNullOrWhiteSpace($running)) {
        Write-AuthRefusal "the sandbox is not running, so there is nothing to sign in to." @(
            "Start it first:  start-sandbox.cmd   (or ./run.sh inside WSL)")
        exit 1
    }
}

# Refuse by name when the capability gate this tool's provider needs is off. Without this the login
# starts and dies several steps later as a proxy 403, which reads as a provider or network fault
# rather than as a switch the operator never turned on.
function Assert-AuthGate {
    param([hashtable]$Row)
    if ($Row.Gate -eq '-') { return }
    $parts = $Row.Gate.Split(':', 2)
    $name = $parts[0]
    $probe = $parts[1]
    if ($probe -eq '-') { return }
    $rc = 1
    try {
        Invoke-AuthDocker exec $script:AuthService grep -qi -- $probe /etc/tinyproxy/filter 2>$null
        $rc = $LASTEXITCODE
    } catch { $rc = 1 }
    if ($rc -ne 0) {
        Write-AuthRefusal "$name is off, so this sign-in would be refused by the egress proxy partway through." @(
            "Set $name=true in .env, run start-sandbox.cmd, then run this again.")
        exit 1
    }
}

# Say where the credential lands and who can read it, on the success path.
function Show-AuthCustody {
    param([hashtable]$Row)
    $tierText = ''
    switch ($Row.Tier) {
        'agent-readable' { $tierText = 'agent-readable container volume' }
        'proxy-vault'    { $tierText = 'proxy-owned same-container vault' }
        'sidecar-owned'  { $tierText = 'sidecar-owned store' }
        'none'           { $tierText = 'no credential' }
        default {
            Write-AuthRefusal "unknown custody tier '$($Row.Tier)' for $($Row.Tool)." @("Fix docs/credential-custody.md.")
            exit 1
        }
    }
    $location = $Row.Path
    if ($Row.Volume -ne '-') { $location = "$location  (volume $($Row.Volume))" }
    Write-Host ""
    Write-Host "Credential custody for $($Row.Tool)"
    Write-Host "  location   $location"
    Write-Host "  tier       $tierText"
    if ($Row.Tier -eq 'agent-readable') {
        Write-Host "             Any process running as the agent user can read this credential."
    }
    Write-Host "  isolation  $($Row.Isolation)"
    Write-Host "  $($Row.Note)"
    Write-Host ""
    Write-Host "Recorded in docs/credential-custody.md; this command changed no tier."
}
