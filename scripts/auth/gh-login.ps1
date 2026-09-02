# Log in to the bundled GitHub CLI (gh) on Windows — the PERMANENT fix for pushing GitHub Actions
# workflow files (.github/workflows/*). A plain repo/Contents PAT cannot push those (GitHub needs
# the `workflow` scope, and a classic PAT's scopes are fixed at creation), but gh's token carries
# `workflow`. Device flow (URL + code in any browser); saved in the persisted gh-config volume so
# you only do this once, and the entrypoint wires git to use it on every start.
$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot '../..')
. (Join-Path $PSScriptRoot 'auth-common.ps1')

Assert-AuthDocker 'gh-login.sh'
$row = Get-AuthRow 'gh'
Assert-AuthStack
Assert-AuthGate $row

Write-Host ""
Write-Host "Starting gh auth login (device flow). When prompted:"
Write-Host "  1. Account: GitHub.com  |  Protocol: HTTPS  |  Authenticate Git: Yes"
Write-Host "  2. 'How would you like to authenticate?' -> Login with a web browser."
Write-Host "  3. gh prints a one-time code + https://github.com/login/device — open it in your"
Write-Host "     browser on this PC, paste the code, and approve (includes the workflow scope)."
Write-Host "  4. gh polls to finish; you'll see 'Logged in as ...'."
Write-Host ""
Write-Host "Saved in the persisted gh-config volume, so you only do this once. Ctrl-C to abort."
Write-Host ""

# Run as node so the login lands in /home/node/.config/gh (persisted) and matches the web-terminal user.
Invoke-AuthDocker exec -it -u node claude-sandbox gh auth login --hostname github.com --git-protocol https --scopes workflow
Invoke-AuthDocker exec -u node claude-sandbox gh auth setup-git --hostname github.com
Invoke-AuthDocker exec -u node claude-sandbox gh auth status

Show-AuthCustody $row
