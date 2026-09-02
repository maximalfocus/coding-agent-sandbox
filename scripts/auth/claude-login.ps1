# Log in to the bundled Claude Code CLI with your Anthropic subscription, on Windows.
#
# Until now Claude was the one bundled agent with no host-side sign-in: the documented path was to
# open the web terminal, run `claude`, and type /login there. That works, but it is the only
# credential in the product an operator has to enter the sandbox to create, and it is the only one
# whose custody tier nothing states.
#
# Runs `claude auth login` - a supported subcommand of the pinned CLI, recorded as
# claude.cli-login-command in docs/provider-contracts.md - inside the container as the node user, so
# the credential lands where the web terminal's own login would put it. Running it as root would
# write a root-owned file the agent user cannot read, which is exactly what issue #108 was.
#
# Works whether Docker is Docker Desktop or runs inside a WSL2 distro; see Resolve-AuthDocker.
$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot '../..')
. (Join-Path $PSScriptRoot 'auth-common.ps1')

Assert-AuthDocker 'claude-login.sh'
$row = Get-AuthRow 'claude'
Assert-AuthStack
Assert-AuthGate $row   # Anthropic egress is always on, so this is a no-op for Claude today

Write-Host ""
Write-Host "Starting claude auth login. Claude will print a URL and a code:"
Write-Host "  1. Open the URL in your browser on this PC."
Write-Host "  2. Approve, and paste the code back if Claude asks for one."
Write-Host "  3. Claude finishes the exchange through the egress proxy."
Write-Host ""
Write-Host "Saved in the persisted Claude config volume, so you only do this once. Ctrl-C to abort."
Write-Host ""

# -it because this flow is interactive; -u node so the credential is owned by the agent user.
Invoke-AuthDocker exec -it -u node claude-sandbox claude auth login --claudeai
Invoke-AuthDocker exec -u node claude-sandbox claude auth status

Show-AuthCustody $row
