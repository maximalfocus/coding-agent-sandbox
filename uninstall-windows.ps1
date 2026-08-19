# uninstall-windows.ps1 - the Windows counterpart to uninstall.sh (and to setup-windows.ps1):
# removes everything this sandbox created on the host, so you can start from a clean slate.
#
# Removes ONLY sandbox-owned resources (names resolved from the compose SANDBOX_* variables) plus this
# repo directory. It NEVER touches your host personal/work trees (PERSONAL_DIR / WORK_DIR), your
# Docker login, your SSH keys, or any WSL distro.
#
#   powershell -ExecutionPolicy Bypass -File .\uninstall-windows.ps1            # prompts, full wipe
#   ...\uninstall-windows.ps1 -Yes                  # no prompt
#   ...\uninstall-windows.ps1 -KeepDockerEngine     # keep Docker Desktop installed
#   ...\uninstall-windows.ps1 -KeepDir              # docker teardown only, keep this directory
#   ...\uninstall-windows.ps1 -SkipDocker           # only remove the directory
#
# Engine removal is gated on a provenance marker that setup-windows.ps1 writes IFF it installed
# Docker Desktop itself - so a pre-existing Docker is never uninstalled unless you pass
# -RemoveDockerEngine. The repo-directory removal is the last step and is handed to a tiny remover
# that runs from %TEMP% after this process exits, so deleting this script mid-run is safe.
#
# To reinstall:
#   git clone https://github.com/maximalfocus/coding-agent-sandbox.git
#   cd coding-agent-sandbox; .\setup-windows.cmd
# ---------------------------------------------------------------------------
param(
    [switch]$Yes,
    [switch]$KeepDir,
    [switch]$KeepImages,
    [switch]$KeepDockerEngine,
    [switch]$RemoveDockerEngine,
    [switch]$PruneDangling,
    [switch]$SkipDocker,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# This script lives at the repo root, so the repo dir is just where it sits. Capture it BEFORE any
# Set-Location, because the final step changes directory away from here to delete it.
$RepoDir = $PSScriptRoot
Set-Location -LiteralPath $RepoDir

# Provenance marker: setup-windows.ps1 writes this iff IT installed Docker Desktop. Lives outside the
# repo so it survives the repo deletion. Engine removal is gated on it (see below).
$EngineMarker = Join-Path $env:USERPROFILE ".coding-agent-sandbox\installed-docker-desktop"

# --- What belongs to the sandbox ---------------------------------------------
# Resolved from the SAME variables the compose files use, defaulting to the fixed names so an
# existing operator sees no change. Fixed names alone meant this script could only ever act on the
# DEFAULT installation, so its removal half could not be exercised on a machine that also held a
# real one - the resources it removes include the operator's login (issue #123). Kept in step with
# uninstall.sh, which consumes the same variable names.
function Get-SandboxName([string]$Name, [string]$Default) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}
$Containers = @(
    (Get-SandboxName 'SANDBOX_CONTAINER_NAME'      'claude-sandbox'),
    (Get-SandboxName 'SANDBOX_MITM_CONTAINER_NAME' 'claude-sandbox-mitm')
)
$Volumes    = @(
    (Get-SandboxName 'SANDBOX_CONFIG_VOLUME_NAME'       'coding-agent-sandbox-config'),
    (Get-SandboxName 'SANDBOX_CODEX_VOLUME_NAME'        'coding-agent-sandbox-codex'),
    (Get-SandboxName 'SANDBOX_GH_VOLUME_NAME'           'coding-agent-sandbox-gh'),
    (Get-SandboxName 'SANDBOX_AUDIT_VOLUME_NAME'        'coding-agent-sandbox-audit'),
    (Get-SandboxName 'SANDBOX_MITM_AUDIT_VOLUME_NAME'   'coding-agent-sandbox-audit-mitm'),
    (Get-SandboxName 'SANDBOX_WORKSPACE_VOLUME_NAME'    'coding-agent-sandbox-workspace'),
    (Get-SandboxName 'SANDBOX_WORK_VOLUME_NAME'         'coding-agent-sandbox-work'),
    (Get-SandboxName 'SANDBOX_PERSONAL_VOLUME_NAME'     'coding-agent-sandbox-personal'),
    (Get-SandboxName 'SANDBOX_WS_VOLUME_NAME'           'coding-agent-sandbox-ws'),
    (Get-SandboxName 'SANDBOX_TRIVY_CACHE_VOLUME_NAME'  'coding-agent-sandbox-trivy-cache')
)
# The compose network is <project>_default; claude-safe-net is created on first use by the optional
# `claude-safe` shell helper (a `docker run` on its own user-defined network).
$Networks = @(((Get-SandboxName 'COMPOSE_PROJECT_NAME' 'coding-agent-sandbox') + "_default"), "claude-safe-net")
# The image tags are NOT parameterised in the compose files, so every installation on a host shares
# them. An addressed run keeps them: removing a shared image is exactly the "touched a resource that
# was not mine" failure this addressability exists to prevent.
$Images     = @("coding-agent-sandbox:latest", "coding-agent-sandbox-mitm:latest")

# Any override means "not the default installation". A PARTIAL override is the dangerous case: it
# resolves some names to a disposable stack and the rest to the operator's, so one run would remove
# both. Refuse rather than guess.
$SandboxVars = @(
    'SANDBOX_CONTAINER_NAME', 'SANDBOX_MITM_CONTAINER_NAME',
    'SANDBOX_CONFIG_VOLUME_NAME', 'SANDBOX_CODEX_VOLUME_NAME', 'SANDBOX_GH_VOLUME_NAME',
    'SANDBOX_WORKSPACE_VOLUME_NAME', 'SANDBOX_WORK_VOLUME_NAME', 'SANDBOX_PERSONAL_VOLUME_NAME',
    'SANDBOX_WS_VOLUME_NAME', 'SANDBOX_AUDIT_VOLUME_NAME', 'SANDBOX_MITM_AUDIT_VOLUME_NAME',
    'SANDBOX_TRIVY_CACHE_VOLUME_NAME', 'COMPOSE_PROJECT_NAME'
)
$SetVars   = @($SandboxVars | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
$UnsetVars = @($SandboxVars | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
$Addressed = ($SetVars.Count -gt 0)
if ($Addressed -and $UnsetVars.Count -gt 0) {
    Write-Error "REFUSING: this run addresses a named installation, but these are unset:
  $($UnsetVars -join ' ')
Each unset name falls back to the DEFAULT - the operator's - so one run would remove resources
from two installations. Set all of them, or none of them."
    exit 1
}

function Show-Usage {
    @"
uninstall-windows.ps1 - remove everything this sandbox created on the host (Windows).

Removes ONLY sandbox-owned Docker resources + this repo directory.

Names come from the same SANDBOX_* variables the compose files use. Set ALL of them
(and COMPOSE_PROJECT_NAME) to remove one named installation instead of the default;
a partial override is refused, because the unset names fall back to the default
installation's.
NEVER touches your host personal/work trees, your Docker login, your SSH keys, or any WSL distro.

Usage:
  powershell -ExecutionPolicy Bypass -File .\uninstall-windows.ps1 [flags]

Flags:
  -Yes                  Don't prompt for confirmation.
  -KeepDir              Tear down Docker resources but keep this directory.
  -KeepImages           Keep the built images (faster re-test; skips a rebuild).
  -KeepDockerEngine     Never touch Docker Desktop.
  -RemoveDockerEngine   Force-uninstall Docker Desktop even if this sandbox didn't install it
                        (default only removes an engine it installed itself).
  -PruneDangling        Also 'docker image prune -f' (removes ALL dangling layers, host-wide).
  -SkipDocker           Do nothing to Docker at all; only remove the directory.
  -Help                 Show this help.
"@ | Write-Host
}

if ($Help) { Show-Usage; exit 0 }

# Default: remove the engine, but ONLY if this sandbox installed it (marker), unless told otherwise.
$DoRemoveEngine = -not $KeepDockerEngine
$ForceEngine = [bool]$RemoveDockerEngine
if ($RemoveDockerEngine) { $DoRemoveEngine = $true }

# An addressed run removes ONE named installation and nothing else. The shared, fixed-name resources
# -- the image tags, the host Docker engine, and this repo directory -- belong to the host rather
# than to that installation, so they are never in scope for it. Kept in step with uninstall.sh
# (issue #123); without this an addressed Windows run would still delete the repo and could
# uninstall Docker Desktop out from under the operator's real installation.
if ($Addressed) {
    $KeepImages = $true
    $KeepDir = $true
    $DoRemoveEngine = $false
    $ForceEngine = $false
    # claude-safe-net is created on first use by the optional `claude-safe` helper and is shared by
    # every installation on the host, so an addressed run leaves it alone too.
    $Networks = @((Get-SandboxName 'COMPOSE_PROJECT_NAME' 'coding-agent-sandbox') + "_default")
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Make sure `docker` resolves even if Docker's bin dir isn't on PATH in this session (mirrors
# setup-windows.ps1 / run.ps1).
function Add-DockerToPathForThisSession {
    $dockerBin = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin"
    if (Test-Path -LiteralPath $dockerBin) { $env:PATH = "$dockerBin;$env:PATH" }
}
Add-DockerToPathForThisSession

function Test-DockerRunning {
    # Guarded: native stderr becomes a TERMINATING NativeCommandError under
    # $ErrorActionPreference='Stop', which `*> $null` redirects but does not prevent. A probe must be
    # able to report "not available" rather than throw (issue #111).
    if (-not (Test-Command "docker")) { return $false }
    $rc = 1
    try { & docker info *> $null; $rc = $LASTEXITCODE } catch { $rc = 1 }
    return ($rc -eq 0)
}

# --- Preview ------------------------------------------------------------------
if ($Addressed) {
    Write-Host "Addressing the named installation '$(Get-SandboxName 'COMPOSE_PROJECT_NAME' 'coding-agent-sandbox')' - not the default one."
    Write-Host "  (images, the host Docker engine and this directory are shared, so they are left alone)"
    Write-Host ""
}
Write-Host "coding-agent-sandbox uninstall (Windows)"
Write-Host "========================================"
Write-Host ""
if (-not $SkipDocker) {
    Write-Host "Docker resources to remove:"
    Write-Host "  containers: $($Containers -join ' ')"
    if ($KeepImages) { Write-Host "  images:     (kept - KeepImages)" }
    else             { Write-Host "  images:     $($Images -join ' ')" }
    Write-Host "  volumes:    $($Volumes -join ' ')"
    Write-Host "              (includes your sandbox Claude/Codex/gh LOGIN; you'll log in again)"
    Write-Host "  network:    $($Networks -join ' ')"
}
else {
    Write-Host "Docker: skipped (-SkipDocker)."
}
if ($KeepDir) { Write-Host "Directory:  kept (-KeepDir)." }
else          { Write-Host "Directory:  $RepoDir   (this whole repo)" }

if ($SkipDocker -or (-not $DoRemoveEngine)) {
    Write-Host "Docker engine: kept."
}
elseif ($ForceEngine) {
    Write-Host "Docker engine: Docker Desktop will be UNINSTALLED (forced)."
}
elseif (Test-Path -LiteralPath $EngineMarker) {
    Write-Host "Docker engine: Docker Desktop will be UNINSTALLED (this sandbox installed it; pass -KeepDockerEngine to keep)."
}
else {
    Write-Host "Docker engine: kept - it pre-existed this sandbox (no install marker). Use -RemoveDockerEngine to force."
}
Write-Host ""
Write-Host "NOT touched: your host personal/work trees (PERSONAL_DIR / WORK_DIR), your Docker login,"
Write-Host "             your SSH keys, and any WSL distro (see the WSL note below)."
Write-Host ""

if (-not $Yes) {
    $ans = Read-Host "Proceed? [y/N]"
    if ($ans -notmatch '^(y|Y|yes|YES)$') { Write-Host "Aborted."; exit 0 }
}

# --- Docker teardown ----------------------------------------------------------
if (-not $SkipDocker) {
    if (-not (Test-Command "docker")) {
        Write-Host ""
        Write-Host "! docker CLI not found - skipping Docker teardown. Resources (if any) remain."
    }
    elseif (-not (Test-DockerRunning)) {
        Write-Host ""
        Write-Host "! Docker daemon isn't running. Start Docker Desktop and re-run,"
        Write-Host "  or pass -SkipDocker to only remove the directory."
        exit 1
    }
    else {
        # Graceful compose down first (handles anything the explicit lists miss).
        Write-Host ""
        Write-Host "==> docker compose down (default + mitm stacks)"
        # Best-effort cleanup: a stderr line here must not abort the uninstall part-way (#111).
        try { & docker compose down --remove-orphans *> $null } catch { }
        if (Test-Path -LiteralPath (Join-Path $RepoDir "docker-compose.mitm.yml")) {
            try { & docker compose -f docker-compose.mitm.yml down --remove-orphans *> $null } catch { }
        }

        Write-Host "==> Removing containers"
        foreach ($c in $Containers) {
            $found = $null
            try { $found = & docker ps -aq -f "name=^$c$" } catch { $found = $null }
            if ($found) {
                # Guarded so the "(could not remove)" branch below is reachable at all (#111).
                $rc = 1
                try { & docker rm -f $c *> $null; $rc = $LASTEXITCODE } catch { $rc = 1 }
                if ($rc -eq 0) { Write-Host "    removed container $c" } else { Write-Host "    (could not remove $c)" }
            }
        }

        Write-Host "==> Removing volumes (logins + audit logs live here)"
        foreach ($v in $Volumes) {
            $found = $null
            try { $found = & docker volume ls -q -f "name=^$v$" } catch { $found = $null }
            if ($found) {
                $rc = 1
                try { & docker volume rm $v *> $null; $rc = $LASTEXITCODE } catch { $rc = 1 }
                if ($rc -eq 0) { Write-Host "    removed volume $v" } else { Write-Host "    (in use? could not remove $v)" }
            }
        }

        if (-not $KeepImages) {
            Write-Host "==> Removing images"
            foreach ($i in $Images) {
                $rc = 1
                try { & docker image inspect $i *> $null; $rc = $LASTEXITCODE } catch { $rc = 1 }
                if ($rc -eq 0) {
                    $rc2 = 1
                    try { & docker image rm -f $i *> $null; $rc2 = $LASTEXITCODE } catch { $rc2 = 1 }
                    if ($rc2 -eq 0) { Write-Host "    removed image $i" } else { Write-Host "    (could not remove $i)" }
                }
            }
        }

        Write-Host "==> Removing network"
        foreach ($n in $Networks) {
            $found = $null
            try { $found = & docker network ls -q -f "name=^$n$" } catch { $found = $null }
            if ($found) {
                $rc = 1
                try { & docker network rm $n *> $null; $rc = $LASTEXITCODE } catch { $rc = 1 }
                if ($rc -eq 0) { Write-Host "    removed network $n" } else { Write-Host "    (could not remove $n)" }
            }
        }

        if ($PruneDangling) {
            Write-Host "==> Pruning dangling images (host-wide)"
            try { & docker image prune -f *> $null } catch { }
        }
    }

    # --- WSL advisory (never automatic) --------------------------------------
    # On Windows, Docker may run via Docker Desktop's WSL2 backend, or via a Docker engine you
    # installed INSIDE a WSL distro. We never unregister a distro: 'wsl --unregister' destroys
    # everything in it - SSH keys, Codex/Claude logins, other projects - not just the sandbox.
    if (Test-Command "wsl") {
        $distros = @()
        try { $distros = @(& wsl.exe -l -q 2>$null | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ }) } catch { }
        if ($distros.Count -gt 0) {
            Write-Host ""
            Write-Host "Note: WSL distro(s) present: $($distros -join ', ')."
            Write-Host "      If you ran Docker inside one, its images live there and were removed above via the"
            Write-Host "      docker CLI. This uninstaller does NOT unregister any distro (that would also destroy"
            Write-Host "      SSH keys, logins, and other data inside it). To remove a distro yourself, AFTER backing"
            Write-Host "      up anything you need, run:  wsl --unregister DistroName"
        }
    }
}

# --- Optional: uninstall the Docker engine ------------------------------------
# Only when the user didn't ask to skip Docker, AND either this sandbox installed the engine
# (marker present) or removal was forced. We never silently uninstall a pre-existing engine.
if ((-not $SkipDocker) -and $DoRemoveEngine) {
    if ($ForceEngine -or (Test-Path -LiteralPath $EngineMarker)) {
        Write-Host ""
        Write-Host "==> Uninstalling Docker Desktop"
        $engineRemoved = $false
        if (Test-Command "winget") {
            & winget uninstall --id Docker.DockerDesktop --exact --silent --accept-source-agreements
            if ($LASTEXITCODE -eq 0) { Write-Host "    uninstalled Docker Desktop"; $engineRemoved = $true }
            else { Write-Host "    (Docker Desktop not installed via winget, or uninstall needs an elevated prompt - re-run as Administrator)" }
        }
        else {
            Write-Host "    winget not found - uninstall Docker Desktop manually from Settings > Apps."
        }
        # Only clear the provenance marker if we ACTUALLY removed the engine - otherwise a failed or
        # still-needed removal could be retried by the default (marker-gated) path next run.
        if ($engineRemoved) {
            Remove-Item -LiteralPath $EngineMarker -Force -ErrorAction SilentlyContinue
            $markerDir = Split-Path -Parent $EngineMarker
            if ((Test-Path -LiteralPath $markerDir) -and -not (Get-ChildItem -LiteralPath $markerDir -Force)) {
                Remove-Item -LiteralPath $markerDir -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Host "    (kept the install marker - nothing was actually uninstalled)"
        }
    }
    else {
        Write-Host ""
        Write-Host "==> Docker engine: leaving it installed - it pre-existed this sandbox (no marker at"
        Write-Host "    $EngineMarker). Re-run with -RemoveDockerEngine to uninstall it anyway."
    }
}

# --- Directory removal (LAST - this script self-destructs) --------------------
# A directory can't be deleted while it's a running process's current directory, and PowerShell holds
# a handle on the executing .ps1. So we hand removal to a tiny remover that runs from %TEMP%, waits
# for THIS process to exit, then deletes the repo. Mirrors uninstall.sh's temp-remover trick.
if (-not $KeepDir) {
    # Sanity guard so a corrupted RepoDir can't nuke the profile or a drive root.
    $homeResolved = (Resolve-Path -LiteralPath $env:USERPROFILE).Path.TrimEnd('\')
    $repoNorm = $RepoDir.TrimEnd('\')
    $root = [System.IO.Path]::GetPathRoot($RepoDir).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($repoNorm) -or $repoNorm -ieq $homeResolved -or $repoNorm -ieq $root) {
        Write-Host ""
        Write-Host "! Refusing to delete '$RepoDir' - leaving the directory in place."
        exit 1
    }

    Write-Host ""
    Write-Host "==> Removing directory $RepoDir"

    $remover = Join-Path $env:TEMP ("cas-uninstall-" + [System.IO.Path]::GetRandomFileName() + ".ps1")
    $removerBody = @'
param([string]$Target, [int]$ParentPid)
try { Wait-Process -Id $ParentPid -Timeout 60 -ErrorAction SilentlyContinue } catch { }
$removed = $false
for ($i = 0; $i -lt 12; $i++) {
    Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Target)) { $removed = $true; break }
    Start-Sleep -Seconds 1
}
if ($removed) {
    Write-Host "    removed $Target"
    Write-Host ""
    Write-Host "Done. Windows is clean. To reinstall:"
    Write-Host "  git clone https://github.com/maximalfocus/coding-agent-sandbox.git `"$Target`""
    Write-Host "  cd `"$Target`"; .\setup-windows.cmd"
}
else {
    Write-Host "    WARNING: could not fully remove $Target - close any shell, editor, or Explorer window"
    Write-Host "    open there, then run:  rmdir /s /q `"$Target`""
}
Write-Host ""
Read-Host "Press Enter to close"
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
'@
    Set-Content -LiteralPath $remover -Value $removerBody -Encoding UTF8

    Set-Location -LiteralPath $env:TEMP   # leave the dir we are about to delete
    Start-Process -FilePath "powershell" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $remover, "-Target", $RepoDir, "-ParentPid", $PID)
    Write-Host "    handed off to a cleanup window - it will confirm when the directory is gone."
    exit 0
}

Write-Host ""
Write-Host "Done."
