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
$compose = @("compose", "-f", "docker-compose.sidecar.yml", "run", "--rm", "--no-deps",
             "deepseek-key-manager", $managerAction)

if ($managerAction -ne "store") {
    & docker @compose
    exit $LASTEXITCODE
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
