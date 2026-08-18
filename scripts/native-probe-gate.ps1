# Finds native-command invocations whose failure the script intends to HANDLE, and requires each to
# be inside a try (issue #117, extending #111).
#
# Under `$ErrorActionPreference = "Stop"` PowerShell turns a native command's stderr into a
# TERMINATING NativeCommandError. Redirection does not prevent it. Measured on 5.1, all three forms
# throw identically:
#
#     & docker info *> $null            <- the only form #111's textual gate matched
#     docker info *> $null
#     $v = docker compose ps … 2>$null
#
# So an unguarded probe throws instead of reporting, and the script's own "not running" message never
# prints. #111 fixed the `&` sites; this finds the rest.
#
# Uses the PARSER rather than a textual scan, because this repository legitimately contains `docker`
# and `git` inside single-quoted shell strings passed to `docker compose exec` — the same false
# positives #76 hit when it scanned text instead of tokens.
#
# A "probe" is a native invocation whose result the script reads: assigned to a variable, or followed
# by a `$LASTEXITCODE` test. An invocation whose failure should simply propagate is an ACTION and is
# left alone.
# `pwsh -File` does not array-bind trailing arguments, so the file list is discovered here rather
# than passed in — a partially-bound list would silently shrink the scan to one file.
$Paths = @(Get-ChildItem -Path . -Recurse -Filter *.ps1 | ForEach-Object { $_.FullName } | Sort-Object)

$NATIVE = @('docker','wsl','git','npm','gh','tar','curl')
$failed = 0
$checked = 0

foreach ($path in $Paths) {
    $errs = $null; $toks = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$toks, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) { Write-Output "PARSE-ERROR $path"; $failed++; continue }

    # Only files that opt into Stop can suffer this.
    $assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    $stops = @($assigns | Where-Object { $_.Left.Extent.Text -eq '$ErrorActionPreference' -and $_.Right.Extent.Text -match 'Stop' })
    if ($stops.Count -eq 0) { continue }

    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if ($NATIVE -notcontains $name) { continue }

        # Probe? assigned, or its exit code inspected by a following statement in the same block.
        $assigned = $false
        $p = $c.Parent
        while ($p) {
            if ($p -is [System.Management.Automation.Language.AssignmentStatementAst]) { $assigned = $true; break }
            if ($p -is [System.Management.Automation.Language.StatementBlockAst]) { break }
            $p = $p.Parent
        }
        $inspected = $false
        $stmt = $c
        while ($stmt -and -not ($stmt.Parent -is [System.Management.Automation.Language.StatementBlockAst])) { $stmt = $stmt.Parent }
        if ($stmt -and $stmt.Parent) {
            $sts = @($stmt.Parent.Statements)
            $idx = [Array]::IndexOf($sts, $stmt)
            if ($idx -ge 0 -and $idx + 1 -lt $sts.Count) {
                if ($sts[$idx + 1].Extent.Text -match '\$LASTEXITCODE') { $inspected = $true }
            }
        }
        if (-not ($assigned -or $inspected)) { continue }   # an action: failure may propagate

        $checked++
        # Guarded?
        $inTry = $false
        $q = $c.Parent
        while ($q) {
            if ($q -is [System.Management.Automation.Language.TryStatementAst]) { $inTry = $true; break }
            $q = $q.Parent
        }
        if (-not $inTry) {
            $failed++
            $rel = (Resolve-Path -Relative $path) -replace '^\.[\\/]', ''
            Write-Output ("UNGUARDED {0}:{1}: {2}" -f $rel, $c.Extent.StartLineNumber, $c.Extent.Text.Split([char]10)[0].Trim())
        }
    }
}
Write-Output ("SUMMARY probes={0} unguarded={1}" -f $checked, $failed)
if ($failed -gt 0) { exit 1 } else { exit 0 }
