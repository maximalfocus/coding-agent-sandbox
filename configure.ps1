# Ordered, resumable configuration for the sandbox - from the HOST (issue #155, CAS-R056).
#
# The POSIX twin is ./configure.sh and the two must stay at parity: same step ids, same order, same
# three states, same refusal to decide anything on the operator's behalf.
#
# This is an ORDERING, STATUS, and RESUMABILITY layer. It reimplements nothing: every step invokes
# the supported path for its concern. It does not replace CAS-R055's in-sandbox checklist either -
# that one stays narrow and inside the sandbox, and both are recomputed from the same observed state
# so they cannot disagree.
#
#   .\configure.ps1                  # report every step's OBSERVED state; changes nothing
#   .\configure.ps1 -Run             # walk in order, performing each unmet step
#   .\configure.ps1 -Step stack      # one step alone (report)
#   .\configure.ps1 -Step gh -Run    # ...or perform it
#   .\configure.ps1 -List            # the step ids, in order
#
# What it will NEVER do without you: enable a capability gate, adopt a pin, or create a credential.
# Those are operator decisions; the flow states the decision and stops.
[CmdletBinding()]
param(
    [switch]$Run,
    [string]$Step,
    [switch]$List
)
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot
. (Join-Path $PSScriptRoot 'scripts/auth/auth-common.ps1')

$Root = (Get-Location).Path
$EnvFile = Join-Path $Root '.env'
$CustodyDoc = Join-Path $Root 'docs/credential-custody.md'
$Svc = 'claude-sandbox'

$script:Satisfied = 0
$script:Unmet = 0
$script:Decision = 0
$script:NotApplicable = 0

function Write-StepState {
    param([string]$Id, [string]$State, [string]$Detail)
    switch ($State) {
        'satisfied' { $script:Satisfied++ }
        'unmet'     { $script:Unmet++ }
        'decision'  { $script:Unmet++; $script:Decision++ }
        'n/a'       { $script:NotApplicable++ }
    }
    Write-Host ("{0,-11} {1,-14} {2}" -f $State, $Id, $Detail)
}

# --- .env, the control plane ------------------------------------------------
function Get-EnvValue {
    param([string]$Name)
    if (-not (Test-Path -LiteralPath $EnvFile)) { return "" }
    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        if ($line -match "^\s*$Name=(.*)$") { return $Matches[1].Trim('"') }
    }
    return ""
}
function Test-Gate {
    param([string]$Name, [string]$Default)
    $v = Get-EnvValue $Name
    if ([string]::IsNullOrEmpty($v)) { $v = $Default }
    return @('true', '1', 'yes', 'on') -contains $v.ToLower()
}

# --- probes: OBSERVED state, never a claim ---------------------------------
function Test-StackUp {
    $running = $null
    try { $running = Invoke-AuthDocker compose ps --status running --format '{{.Name}}' 2>$null } catch { $running = $null }
    return -not [string]::IsNullOrWhiteSpace($running)
}
function Invoke-InAgent {
    param([string]$Command)
    try {
        Invoke-AuthDocker compose exec -T -u node $Svc sh -lc $Command *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# Observed EXACTLY the way entrypoint.sh derives GIT_CREDS_OK, so this flow and CAS-R055's
# in-sandbox checklist cannot disagree: a stored gh login probed with the env tokens cleared (gh
# would otherwise report "logged in" merely because GITHUB_TOKEN is set), or a GITHUB_TOKEN.
function Test-GhCredential {
    if (Invoke-InAgent 'env -u GITHUB_TOKEN -u GH_TOKEN gh auth status --hostname github.com') { return $true }
    return (Invoke-InAgent 'test -n "${GITHUB_TOKEN:-}"')
}

# --- the sign-in steps, derived from the custody table ---------------------
function Get-CustodyRows {
    $rows = @()
    if (-not (Test-Path -LiteralPath $CustodyDoc)) { return $rows }
    $inBlock = $false
    foreach ($line in [System.IO.File]::ReadAllLines($CustodyDoc)) {
        if ($line -eq '```credential-custody') { $inBlock = $true; continue }
        if ($inBlock -and $line.StartsWith('```')) { break }
        if (-not $inBlock) { continue }
        $text = $line.Trim()
        if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }
        $f = $text.Split('|')
        if ($f.Count -ne 9) { continue }
        if ($f[2].Trim() -eq '-') { continue }
        $rows += @{ Id = $f[0].Trim(); Tool = $f[1].Trim(); Command = $f[2].Trim(); Gate = $f[3].Trim() }
    }
    return $rows
}

function Test-SignIn {
    param([string]$Id)
    switch ($Id) {
        # 2>&1, not 2>$null: codex reports its login status on STDERR.
        'claude' { return (Invoke-InAgent 'claude auth status 2>&1 | grep -q "\"loggedIn\": true"') }
        'codex'  { return (Invoke-InAgent 'codex login status 2>&1 | grep -qi "logged in"') }
        'gh'     { return (Test-GhCredential) }
        'pi'     {
            try { & powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts/auth/deepseek-key.ps1') status *> $null } catch { return $false }
            return ($LASTEXITCODE -eq 0)
        }
    }
    return $false
}

# --- the ordered step list -------------------------------------------------
$CustodyRows = Get-CustodyRows
$StepIds = @('env', 'stack', 'pins') + ($CustodyRows | ForEach-Object { $_.Id }) + @('skills')

if ($List) { $StepIds | ForEach-Object { Write-Host $_ }; exit 0 }
if ($Step -and ($StepIds -notcontains $Step)) {
    Write-Error "unknown step '$Step' (see -List)"
    exit 2
}
if (-not (Resolve-AuthDocker)) {
    Write-Host "REFUSING: Docker was not found. Start Docker Desktop, or run ./configure.sh from a WSL Ubuntu shell."
    exit 2
}

# --- steps ------------------------------------------------------------------
function Step-Env {
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        $example = Join-Path $Root '.env.example'
        if ($Run -and (Test-Path -LiteralPath $example)) {
            Copy-Item -LiteralPath $example -Destination $EnvFile
            Write-StepState 'env' 'decision' ".env created from .env.example - set TTYD_PASS to something of your own, then re-run"
            return $false
        }
        Write-StepState 'env' 'unmet' "no .env - run setup-windows.cmd, or .\configure.ps1 -Step env -Run to copy .env.example"
        return $false
    }
    $pass = Get-EnvValue 'TTYD_PASS'
    if (@('', 'changeme', 'please-change-me', 'password', 'coder', 'admin') -contains $pass) {
        Write-StepState 'env' 'decision' "TTYD_PASS is unset or a shipped placeholder; only you can choose it. Edit $EnvFile"
        return $false
    }
    Write-StepState 'env' 'satisfied' ".env present, TTYD_PASS set"
    return $true
}

function Step-Stack {
    if (Test-StackUp) { Write-StepState 'stack' 'satisfied' "the sandbox is running"; return $true }
    if ($Run) {
        Write-Host "  -> run.ps1"
        & powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'run.ps1')
        if (Test-StackUp) { Write-StepState 'stack' 'satisfied' "started by run.ps1"; return $true }
        Write-StepState 'stack' 'unmet' "run.ps1 finished but no container is running"
        return $false
    }
    Write-StepState 'stack' 'unmet' "not running - start-sandbox.cmd (this flow can do it: -Step stack -Run)"
    return $false
}

function Step-Pins {
    $out = ""
    try { $out = (& powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts/update-agent-clis.ps1') 2>&1 | Out-String) } catch { $out = "" }
    # The tool's own definitive line, not a verdict assembled from its table: a per-row "up to date"
    # is true of that row alone.
    if ($out -match 'Every selected pin is already current') {
        Write-StepState 'pins' 'satisfied' "every agent-CLI pin matches its published version"
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($out)) {
        Write-StepState 'pins' 'unmet' "the pin report could not complete"
        return $false
    }
    # Adopting a pin is a rebuild AND a revalidation (CAS-R066/CAS-R067). The flow shows the gap;
    # it never writes one.
    Write-StepState 'pins' 'decision' "a pin differs from its published version; adopting one is your call - .\scripts\update-agent-clis.ps1"
    ($out -split "`n") | ForEach-Object { Write-Host ("      " + $_) }
    return $false
}

function Step-SignIn {
    param([hashtable]$Row)
    if (-not (Test-StackUp)) {
        Write-StepState $Row.Id 'unmet' "the sandbox is not running, so $($Row.Tool)'s credential cannot be observed"
        return $false
    }
    if ($Row.Gate -ne '-') {
        $gateName = $Row.Gate.Split(':', 2)[0]
        if (-not (Test-Gate $gateName 'false')) {
            # A capability grant is an operator decision. The flow states it and stops; it never
            # turns a gate on, because that is egress the operator did not ask for.
            Write-StepState $Row.Id 'decision' "$gateName is off in .env, so $($Row.Tool) cannot sign in; enabling it is a capability grant only you can make"
            return $false
        }
    }
    if (Test-SignIn $Row.Id) { Write-StepState $Row.Id 'satisfied' "$($Row.Tool) is signed in"; return $true }
    if ($Run) {
        Write-Host "  -> scripts\auth\$($Row.Command).ps1"
        try { & powershell -ExecutionPolicy Bypass -File (Join-Path $Root "scripts/auth/$($Row.Command).ps1") } catch { }
        if (Test-SignIn $Row.Id) {
            Write-StepState $Row.Id 'satisfied' "$($Row.Tool) signed in by scripts\auth\$($Row.Command).ps1"
            return $true
        }
    }
    Write-StepState $Row.Id 'unmet' "$($Row.Tool) is not signed in - scripts\auth\$($Row.Command).ps1"
    return $false
}

function Step-Skills {
    $repos = Get-EnvValue 'SKILL_REPOS'
    if ([string]::IsNullOrWhiteSpace($repos)) {
        # Driven by the operator's configured list. The product ships no roster of skill
        # repositories, so "none configured" is not unfinished setup.
        Write-StepState 'skills' 'n/a' "SKILL_REPOS is empty in .env; skill repositories are optional"
        return $true
    }
    if (-not (Test-StackUp)) {
        Write-StepState 'skills' 'unmet' "the sandbox is not running, so the skill clones cannot be observed"
        return $false
    }
    $missing = @()
    foreach ($url in ($repos -split '\s+')) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        $name = ($url -split '/')[-1] -replace '\.git$', ''
        if (-not (Invoke-InAgent "test -d /workspace/personal/$name/.git")) { $missing += $name }
    }
    if ($missing.Count -eq 0) { Write-StepState 'skills' 'satisfied' "every configured skill repository is cloned"; return $true }
    if ($Run) {
        Write-Host "  -> scripts\skills\skills-setup.ps1"
        try { & powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts/skills/skills-setup.ps1') } catch { }
        $missing = @()
        foreach ($url in ($repos -split '\s+')) {
            if ([string]::IsNullOrWhiteSpace($url)) { continue }
            $name = ($url -split '/')[-1] -replace '\.git$', ''
            if (-not (Invoke-InAgent "test -d /workspace/personal/$name/.git")) { $missing += $name }
        }
        if ($missing.Count -eq 0) { Write-StepState 'skills' 'satisfied' "cloned by scripts\skills\skills-setup.ps1"; return $true }
    }
    Write-StepState 'skills' 'unmet' ("not cloned: " + ($missing -join ' ') + " - scripts\skills\skills-setup.ps1")
    return $false
}

# --- walk -------------------------------------------------------------------
Write-Host "Configuration steps, in order. State is OBSERVED, not assumed."
Write-Host ""

$stop = $false
foreach ($id in $StepIds) {
    if ($stop) { break }
    if ($Step -and $Step -ne $id) { continue }
    $okStep = $true
    switch ($id) {
        'env'    { $okStep = Step-Env }
        'stack'  { $okStep = Step-Stack }
        'pins'   { $okStep = Step-Pins }
        'skills' { $okStep = Step-Skills }
        default {
            $row = $CustodyRows | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if ($row) { $okStep = Step-SignIn $row }
        }
    }
    if (-not $okStep -and $Run -and -not $Step -and @('env', 'stack') -contains $id) { $stop = $true }
}

Write-Host ""
Write-Host ("{0} satisfied, {1} unmet, {2} not applicable" -f $script:Satisfied, $script:Unmet, $script:NotApplicable)
if ($stop) {
    Write-Host "STOPPED: a step this flow cannot complete on its own. Nothing after it was attempted."
} elseif ($script:Decision -gt 0) {
    Write-Host ("DECISIONS: {0} step(s) need a choice only you can make - a capability grant, a credential, or a pin." -f $script:Decision)
}
if (-not $Run -and $script:Unmet -gt 0) {
    Write-Host "This was a report; nothing was changed. Add -Run to perform the steps that do not need a decision."
}
if ($script:Unmet -gt 0) { exit 1 }
exit 0
