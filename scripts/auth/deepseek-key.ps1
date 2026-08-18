# Manage the real DeepSeek API key in the dedicated egress-sidecar volume. The key is passed only
# on stdin to a one-off sidecar container; it is never a Compose environment value or argument.
$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot '../..')

if ($args.Count -ne 1 -or $args[0] -notin @("provision", "rotate", "status", "revoke")) {
    Write-Error "Usage: .\scripts\auth\deepseek-key.ps1 {provision|rotate|status|revoke}"
    exit 2
}

$managerAction = switch ($args[0]) {
    "provision" { "store" }
    "rotate"    { "store" }
    "status"    { "status" }
    "revoke"    { "delete" }
}
# Scope to the selected project, the same way sidecar-smoketest.sh and claim-token do. Without `-p`
# this cannot address a stack started with one (issue #95).
$scope = @()
if ($env:SIDECAR_COMPOSE_PROJECT) { $scope = @("-p", $env:SIDECAR_COMPOSE_PROJECT) }
$compose = @("compose") + $scope + @("-f", "docker-compose.sidecar.yml", "run", "--rm", "--no-deps",
             "deepseek-key-manager", $managerAction)

# `-p` does not scope the volumes, so a run that declares isolation can still act on the operator's
# real key — `store` overwrites it and `delete` removes it, with no validation step to fail closed
# against. Guards every action, matching scripts/auth/deepseek-key.sh (issue #97).
#
# Resolved from `compose config` because this service runs via `run --rm`: there is no container to
# inspect until it is already too late.
if ($env:SIDECAR_COMPOSE_PROJECT) {
    $configArgs = @("compose") + $scope + @("-f", "docker-compose.sidecar.yml", "config")
    # A resolution probe must be able to fail without throwing: native stderr terminates under
    # $ErrorActionPreference='Stop' regardless of the redirect (issue #111).
    $rendered = $null
    try { $rendered = & docker @configArgs 2>$null } catch { $rendered = $null }
    # A guard that cannot resolve must REFUSE, not proceed. Catching the terminating error above
    # would otherwise leave $rendered empty, $shared empty, and the check below silently passing —
    # fail-open on a possibly-shared credential volume, which is the opposite of #97's intent.
    if (-not $rendered) {
        Write-Error "REFUSING: could not resolve this stack's volumes via 'docker compose config', so
  whether it shares the operator's DeepSeek key cannot be determined. Refusing rather than guessing."
        exit 1
    }
    $inVolumes = $false
    $resolved = @()
    foreach ($line in $rendered) {
        if ($line -match '^volumes:') { $inVolumes = $true; continue }
        if ($line -match '^[a-z]') { $inVolumes = $false }
        if ($inVolumes -and $line -match '^\s+name:\s*"?([^"]+)"?\s*$') { $resolved += $Matches[1] }
    }
    $defaults = Select-String -Path docker-compose.sidecar.yml -Pattern 'name:\s*"?\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}' |
                ForEach-Object { $_.Matches[0].Groups[1].Value }
    $shared = @($resolved | Where-Object { $defaults -contains $_ })
    if ($shared.Count -gt 0 -and $env:SIDECAR_ALLOW_SHARED_VOLUMES -ne "true") {
        Write-Error "REFUSING: project '$env:SIDECAR_COMPOSE_PROJECT' mounts the operator's own volumes: $($shared -join ' ')
  A '$($args[0])' here would act on the operator's real DeepSeek key, not this stack's.
  Set the volume variables documented at the top of sidecar-smoketest.sh, or
  `$env:SIDECAR_ALLOW_SHARED_VOLUMES=`"true`" if you mean it."
        exit 1
    }
}

if ($managerAction -ne "store") {
    # Guarded so docker's exit code still reaches the caller: an unguarded native stderr write throws
    # under $ErrorActionPreference='Stop', replacing the code with a stack trace (issues #111, #117).
    $rc = 1
    try { & docker @compose; $rc = $LASTEXITCODE } catch { $rc = 1 }
    exit $rc
}

$secure = Read-Host "DeepSeek API key" -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ([string]::IsNullOrEmpty($plain)) { throw "No key supplied" }
    $plain | & docker @compose
    $result = $LASTEXITCODE
} finally {
    if ($null -ne $pointer) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    $plain = $null
    $secure.Dispose()
}
exit $result
