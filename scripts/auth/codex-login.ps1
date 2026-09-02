# Log in to the bundled Codex CLI with your ChatGPT/OpenAI subscription, on Windows.
# Uses the DEVICE-AUTH flow (Codex's recommended path for headless/containerized machines): it
# prints a URL + code, you authorize in any browser, and Codex polls OpenAI through the egress
# proxy to finish — no localhost:1455 loopback callback. Saved in the persisted codex volume.
#
# Works whether Docker is Docker Desktop or runs inside a WSL2 distro; see Resolve-AuthDocker in
# scripts/auth/auth-common.ps1, which also carries the shared stack/gate guards and the custody
# disclosure this command prints on success.
$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot '../..')
. (Join-Path $PSScriptRoot 'auth-common.ps1')

Assert-AuthDocker 'codex-login.sh'
$row = Get-AuthRow 'codex'
Assert-AuthStack
Assert-AuthGate $row

Write-Host ""
Write-Host "Starting codex login --device-auth. Codex will print a URL and a short code:"
Write-Host "  1. Open the URL in your browser on this PC."
Write-Host "  2. Enter the code and sign in with your ChatGPT / OpenAI subscription."
Write-Host "  3. Codex polls to finish — the terminal will say it's logged in."
Write-Host ""
Write-Host "Saved in the persisted codex volume, so you only do this once. Ctrl-C to abort."
Write-Host ""

# Run as node so the login lands in /home/node/.codex (persisted) and matches the web-terminal user.
Invoke-AuthDocker exec -it -u node claude-sandbox codex login --device-auth

Show-AuthCustody $row
