# Assert that an ADVISORY scan stays advisory on Windows PowerShell 5.1 (issue #119).
#
# A scanner writes progress and INFO to **stderr** on a completely successful run. Under
# `$ErrorActionPreference = "Stop"` 5.1 turns native stderr into a TERMINATING NativeCommandError,
# and redirection does not prevent it -- so `scan.ps1` aborted, and with it `run.ps1` and
# `setup-windows.ps1`, on a healthy image. The fix is to relax the preference around each scanner
# call and read the exit code, which is the scanner's real verdict.
#
# Checked with the PARSER rather than a textual scan: this repository has twice been burned by
# regex-based structure checks (#76, #117), and `scan.ps1` legitimately contains `docker` inside
# strings and arguments.
#
# Reads ./scan.ps1, so a copy in a scratch directory can be used to prove the check able to fail.
$path = './scan.ps1'
if (-not (Test-Path $path)) { Write-Output "MISSING scan.ps1"; exit 2 }

$errs = $null; $toks = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count -gt 0) { Write-Output "PARSE-ERROR"; exit 1 }

# Only files that opt into Stop can suffer this at all.
$assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
$stops = @($assigns | Where-Object { $_.Left.Extent.Text -eq '$ErrorActionPreference' -and $_.Right.Extent.Text -match 'Stop' })
if ($stops.Count -eq 0) { Write-Output "SUMMARY scanner-calls=0 unrelaxed=0 (file does not opt into Stop)"; exit 0 }

$SCANNERS = @('trivy', 'docker')
$checked = 0; $failed = 0

foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $c.GetCommandName()
    if (-not $name) { continue }
    if ($SCANNERS -notcontains $name) { continue }
    # `docker image inspect` is a presence probe, not a scanner run: it emits no progress, and its
    # own guard is #120's business rather than this check's.
    if ($c.Extent.Text -match '^\s*docker\s+image\s+inspect') { continue }
    $checked++

    $try = $null; $q = $c.Parent
    while ($q) {
        if ($q -is [System.Management.Automation.Language.TryStatementAst]) { $try = $q; break }
        $q = $q.Parent
    }
    if (-not $try) {
        Write-Output ("UNRELAXED scan.ps1:{0}: not inside a try" -f $c.Extent.StartLineNumber); $failed++; continue
    }
    $relaxed = @($try.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
        Where-Object {
            $_.Left.Extent.Text -eq '$ErrorActionPreference' -and
            $_.Right.Extent.Text -notmatch 'Stop' -and
            $_.Extent.StartOffset -lt $c.Extent.StartOffset
        })
    if ($relaxed.Count -eq 0) {
        Write-Output ("UNRELAXED scan.ps1:{0}: nothing relaxes `$ErrorActionPreference before the call" -f $c.Extent.StartLineNumber)
        $failed++; continue
    }
    $restored = @()
    if ($try.Finally) {
        $restored = @($try.Finally.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
            Where-Object { $_.Left.Extent.Text -eq '$ErrorActionPreference' })
    }
    if ($restored.Count -eq 0) {
        Write-Output ("UNRESTORED scan.ps1:{0}: no finally puts `$ErrorActionPreference back" -f $c.Extent.StartLineNumber)
        $failed++; continue
    }
}

Write-Output ("SUMMARY scanner-calls={0} unrelaxed={1}" -f $checked, $failed)
if ($failed -gt 0) { exit 1 } else { exit 0 }
