# Parses every PowerShell file handed to it and rejects syntax that Windows PowerShell 5.1 cannot
# accept (issue #76, CAS-R162). Runs inside the pinned container started by
# scripts/test-powershell-syntax.sh; it is not meant to be invoked directly.
#
# Two distinct failures are reported:
#
#   1. a parse error — the file is not valid PowerShell at all; and
#   2. a 7-only construct — the file parses under PowerShell 7, which this container runs, but the
#      construct did not exist in 5.1, so a Windows user on the shipped shell would fail to parse it.
#
# The second check reads the PARSER'S TOKEN STREAM rather than the file text. That matters here: this
# repository's PowerShell files legitimately contain `||` inside single-quoted shell strings passed
# to `docker compose exec`, and a textual scan flags every one of them. Tokens carry no such
# ambiguity — an operator inside a string literal is part of the string token, not an operator token.
#
# This is a syntax gate, not a runtime. It parses; it never executes a script under test.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Root
)

$ErrorActionPreference = 'Stop'

# Operators that PowerShell 7 accepts and Windows PowerShell 5.1 cannot parse. Keyed by token kind so
# the check is exact; the value is what to tell someone who hits it.
$SevenOnly = @{
    'QuestionQuestion'       = 'null-coalescing "??" is PowerShell 7+; use an explicit if/else'
    'QuestionQuestionEquals' = 'null-coalescing assignment "??=" is PowerShell 7+'
    'QuestionDot'            = 'null-conditional "?." is PowerShell 7+'
    'QuestionLBracket'       = 'null-conditional index "?[" is PowerShell 7+'
    # Only the ternary operator produces QuestionMark. The familiar `?` alias for Where-Object is a
    # command name and tokenises as Generic, so this does not flag `Get-Process | ? { … }`.
    'QuestionMark'           = 'ternary "? :" is PowerShell 7+; use an explicit if/else'
    'AndAnd'                 = 'pipeline chain "&&" is PowerShell 7+; use separate statements'
    'OrOr'                   = 'pipeline chain "||" is PowerShell 7+; use separate statements'
}

if (-not (Test-Path -LiteralPath $Root)) {
    Write-Output "GATE-ERROR root path not found: $Root"
    exit 2
}

# Materialised with @(...) deliberately. An unwrapped pipeline result is enumerated once and then
# exhausted, which made the count report 0 after the loop had already parsed every file — and, worse,
# left the guard below fail-open: `.Count` on the un-materialised value is $null, `$null -eq 0` is
# false, so a tree with no PowerShell files at all would have "passed" having parsed nothing.
$files = @(
    Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|graphify-out|node_modules)[\\/]' } |
        Sort-Object FullName
)

if ($files.Count -lt 1) {
    Write-Output 'GATE-ERROR no PowerShell files found to parse'
    exit 2
}

$failures = 0
foreach ($file in $files) {
    $relative = $file.FullName.Substring($Root.Length).TrimStart('/', '\')
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors -and $errors.Count -gt 0) {
        $failures++
        foreach ($parseError in $errors) {
            $line = $parseError.Extent.StartLineNumber
            Write-Output "PARSE-ERROR ${relative}:${line} $($parseError.Message)"
        }
        # A file that does not parse cannot be token-scanned meaningfully.
        continue
    }

    $flagged = 0
    foreach ($token in $tokens) {
        $kind = $token.Kind.ToString()
        if ($SevenOnly.ContainsKey($kind)) {
            $flagged++
            $line = $token.Extent.StartLineNumber
            Write-Output "INCOMPATIBLE ${relative}:${line} $($SevenOnly[$kind])"
        }
    }
    if ($flagged -gt 0) { $failures++ }

    Write-Output "PARSED $relative"
}

$total = $files.Count
Write-Output ('GATE-SUMMARY files={0} failed={1}' -f $total, $failures)
if ($failures -gt 0) { exit 1 }
exit 0
