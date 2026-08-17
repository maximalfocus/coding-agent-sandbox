# Parses every .ps1 below the current directory using the runtime's OWN parser, and refuses to be
# read as evidence unless that runtime is Windows PowerShell 5.1 (issue #104, CAS-R162).
#
# This is the other half of scripts/test-powershell-syntax.sh. That gate runs pwsh 7.6.5 and infers
# 5.1 incompatibility from the parser's token stream — the file parses under 7, and constructs that
# did not exist in 5.1 are rejected. The inference is sound and stays the per-change gate. Here the
# property is asserted directly: under real 5.1 a 7-only construct is not a token to recognise, it is
# a parse error.
#
# It is shipped rather than sent inline so that what runs on the Windows host is a reviewable file in
# this repository — and so that it is itself covered by the container gate, which parses every
# tracked .ps1 including this one.
#
# Run through scripts/verify-powershell-runtime.sh, which reaches the host by stable identity.
# Exit 0 = every file parsed and the negative control failed as it must; 1 = something did not;
# 3 = the runtime is not the one this pass exists to exercise.

$ErrorActionPreference = 'Stop'

$v  = $PSVersionTable.PSVersion
$ed = $PSVersionTable.PSEdition
Write-Output ("RUNTIME version={0} edition={1} arch={2}" -f $v, $ed, $env:PROCESSOR_ARCHITECTURE)

# Refuse rather than report a pass from the wrong shell. A green run here is meant to be read as
# "real 5.1 accepted these files"; from pwsh 7 that sentence would be false.
if ($v.Major -ne 5) {
    Write-Output 'FATAL runtime is not PowerShell 5.x — this pass proves nothing here'
    exit 3
}
if ($ed -ne 'Desktop') {
    Write-Output 'FATAL runtime is not the Desktop edition — this is not Windows PowerShell'
    exit 3
}

$failed = 0
$parsed = 0

Get-ChildItem -Path . -Recurse -Filter *.ps1 | Sort-Object FullName | ForEach-Object {
    $errs = $null
    $toks = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$toks, [ref]$errs)
    $rel = (Resolve-Path -Relative $_.FullName) -replace '^\.[\\/]', ''
    if ($errs -and $errs.Count -gt 0) {
        $failed++
        Write-Output ("FAIL {0} :: {1}" -f $rel, $errs[0].Message)
    } else {
        $parsed++
        Write-Output ("PASS {0} tokens={1}" -f $rel, $toks.Count)
    }
}

# Negative control. Without it a green run is indistinguishable from a parser that accepts anything,
# which is the failure mode this repository has removed from several other gates.
$probe = Join-Path $env:TEMP 'cas-negative-control.ps1'
Set-Content -Path $probe -Value '$x = 1 ?? 2' -Encoding ascii
$errs = $null
$toks = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probe, [ref]$toks, [ref]$errs)
Remove-Item $probe -Force -ErrorAction SilentlyContinue
if ($errs -and $errs.Count -gt 0) {
    Write-Output 'CONTROL rejected-7-only-syntax-as-expected'
} else {
    Write-Output 'CONTROL ACCEPTED-7-ONLY-SYNTAX'
    $failed++
}

Write-Output ("SUMMARY parsed={0} failed={1}" -f $parsed, $failed)
if ($failed -gt 0) { exit 1 } else { exit 0 }
