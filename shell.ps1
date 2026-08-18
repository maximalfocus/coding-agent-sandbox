# Open Herdr in a local terminal with the same sandbox isolation as the browser.
#   ./shell.ps1            # attach another Herdr client to its persistent session
#   ./shell.ps1 -Shell     # escape hatch: a fresh Bash shell in /workspace
#   ./shell.ps1 -Attach    # backward-compatible alias for the default
#
# Works whether Docker is Docker Desktop (the `docker` CLI is on the Windows PATH) OR runs inside
# a WSL2 distro (the ./setup-wsl.sh path, where dockerd lives in Ubuntu and never reaches the
# Windows PATH). When `docker` isn't on the PATH we transparently proxy through
# `wsl -d <distro> -- docker`. Set $env:SANDBOX_WSL_DISTRO if the daemon isn't in your default distro.
param([switch]$Attach, [switch]$Shell)
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

# Resolve how to reach the Docker CLI and stash it in script-scope vars used by Invoke-Docker:
#   $DockerExe / $DockerLead = 'docker' / @()                         -> Docker Desktop
#   $DockerExe / $DockerLead = 'wsl'    / @('-d','Ubuntu','--','docker') -> docker inside WSL
# Returns $true on success, $false if no working Docker could be found.
function Resolve-Docker {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $script:DockerExe = 'docker'; $script:DockerLead = @()
        return $true
    }
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        $distro = $env:SANDBOX_WSL_DISTRO
        # [string[]] keeps this an ARRAY: PowerShell would otherwise unwrap a 1-element @('--')
        # to the scalar '--', turning the later '+' into string concat ('--docker version ...').
        [string[]]$pre = if ([string]::IsNullOrWhiteSpace($distro)) { @('--') } else { @('-d', $distro, '--') }
        # Confirm docker actually answers inside WSL before committing to this path.
        #
        # Guarded because a probe must be able to report "not available". `wsl.exe` writes to stderr
        # when the subsystem is absent, and under $ErrorActionPreference='Stop' PowerShell turns
        # native stderr into a TERMINATING NativeCommandError — `*> $null` redirects the stream but
        # does not prevent the error. Unguarded, this throws instead of falling through to the
        # caller's fail-closed message, and the operator gets a stack trace (issue #111).
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

function Invoke-Docker {
    param([Parameter(ValueFromRemainingArguments = $true)]$DockerArgs)
    & $script:DockerExe @($script:DockerLead + $DockerArgs)
}

if (-not (Resolve-Docker)) {
    Write-Host "Docker not found. Start Docker Desktop, or — if you provisioned Docker inside WSL"
    Write-Host "(./setup-wsl.sh) — run './shell.sh --attach' from a WSL Ubuntu shell instead."
    exit 1
}

# Is the sandbox container up? (Match by the fixed container_name so we don't depend on being
# invoked from the compose project directory — works the same through Docker Desktop or WSL.)
$running = Invoke-Docker ps --filter 'name=^claude-sandbox$' --filter 'status=running' --format '{{.Names}}'
if ([string]::IsNullOrWhiteSpace($running)) {
    Write-Host "Sandbox isn't running. Start it first:  ./run.ps1   (or ./run.sh inside WSL)"
    exit 1
}

if ($Shell) {
    Invoke-Docker exec -it -u node -w /workspace claude-sandbox bash -l
} else {
    Invoke-Docker exec -it -u node -w /workspace claude-sandbox herdr
}
