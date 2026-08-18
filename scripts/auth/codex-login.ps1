# Log in to the bundled Codex CLI with your ChatGPT/OpenAI subscription, on Windows.
# Uses the DEVICE-AUTH flow (Codex's recommended path for headless/containerized machines): it
# prints a URL + code, you authorize in any browser, and Codex polls OpenAI through the egress
# proxy to finish — no localhost:1455 loopback callback. Saved in the persisted codex volume.
#
# Works whether Docker is Docker Desktop (the `docker` CLI is on the Windows PATH) OR runs inside
# a WSL2 distro (the ./setup-wsl.sh path, where dockerd lives in Ubuntu and never reaches the
# Windows PATH). When `docker` isn't on the PATH we transparently proxy through
# `wsl -d <distro> -- docker`. Set $env:SANDBOX_WSL_DISTRO if the daemon isn't in your default distro.
$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot '../..')

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
    Write-Host "(./setup-wsl.sh) — run './scripts/auth/codex-login.sh' from a WSL Ubuntu shell instead."
    exit 1
}

# Is the sandbox container up? (Match by the fixed container_name so we don't depend on being
# invoked from the compose project directory — works the same through Docker Desktop or WSL.)
$running = Invoke-Docker ps --filter 'name=^claude-sandbox$' --filter 'status=running' --format '{{.Names}}'
if ([string]::IsNullOrWhiteSpace($running)) {
    Write-Host "Sandbox isn't running. Start it first:  start-sandbox.cmd   (or ./run.sh inside WSL)"
    exit 1
}

# OpenAI egress must be on, or device-auth polling is refused (403) by the proxy.
Invoke-Docker exec claude-sandbox grep -q "openai" /etc/tinyproxy/filter
if ($LASTEXITCODE -ne 0) {
    Write-Host "OpenAI egress is not enabled. Set ALLOW_OPENAI=true in .env, run start-sandbox.cmd,"
    Write-Host "then run this again."
    exit 1
}

Write-Host ""
Write-Host "Starting codex login --device-auth. Codex will print a URL and a short code:"
Write-Host "  1. Open the URL in your browser on this PC."
Write-Host "  2. Enter the code and sign in with your ChatGPT / OpenAI subscription."
Write-Host "  3. Codex polls to finish — the terminal will say it's logged in."
Write-Host ""
Write-Host "Saved in the persisted codex volume, so you only do this once. Ctrl-C to abort."
Write-Host ""

# Run as node so the login lands in /home/node/.codex (persisted) and matches the web-terminal user.
Invoke-Docker exec -it -u node claude-sandbox codex login --device-auth
