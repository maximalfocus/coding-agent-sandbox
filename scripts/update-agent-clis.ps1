# Update the pinned agent-CLI versions FROM THE HOST (Windows).
#
#   .\scripts\update-agent-clis.ps1                     # report only - changes nothing
#   .\scripts\update-agent-clis.ps1 -Apply              # move every pin to the published version
#   .\scripts\update-agent-clis.ps1 -Apply claude       # ...only the ones you name
#   .\scripts\update-agent-clis.ps1 -Apply codex=0.150.0
#
# Why the host: the CLIs are pinned at build time and their runtime self-update is disabled, so the
# running CLI cannot drift mid-session. Updating from inside the sandbox would mean turning on
# ALLOW_TOOL_UPGRADES and letting the container fetch its own tooling - trading a reviewable
# build-time pin for unreviewed runtime drift. The registry lookup therefore happens here, over the
# host's own network, and the sandbox's egress grants are left exactly as they are.
#
# This is not an auto-updater. It writes nothing without -Apply, and it never rebuilds.
#
# POSIX twin: scripts/update-agent-clis.sh. Kept at parity deliberately.
#
# Note on the parameter block: names are read from $args rather than through
# [Parameter(ValueFromRemainingArguments)], which would make this an advanced command and bind a
# bare -c or -w to an ambiguous common parameter. That is issue #115, and it is not repeated here.
# This file is pure ASCII so Windows PowerShell 5.1 reads the bytes written, per issue #106.

param(
    [switch]$Apply,
    [string]$Dockerfile = "Dockerfile"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

# 5.1 does not negotiate TLS 1.2 by default on older hosts; the registry requires it.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "could not raise the TLS version; continuing with the default"
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $RepoRoot
try {
    $Catalog = @(
        @{ Name = "claude";   Arg = "CLAUDE_CODE_VERSION"; Package = "@anthropic-ai/claude-code" },
        @{ Name = "codex";    Arg = "CODEX_VERSION";       Package = "@openai/codex" },
        @{ Name = "opencode"; Arg = "OPENCODE_VERSION";    Package = "opencode-ai" },
        @{ Name = "pi";       Arg = "PI_VERSION";          Package = "@earendil-works/pi-coding-agent" }
    )

    $selected = @()
    $pins = @{}
    foreach ($token in $args) {
        $text = [string]$token
        if ($text.Length -eq 0) { continue }
        $name = $text
        $wanted = ""
        if ($text.Contains("=")) {
            $name = $text.Substring(0, $text.IndexOf("="))
            $wanted = $text.Substring($text.IndexOf("=") + 1)
        }
        $known = $false
        foreach ($entry in $Catalog) { if ($entry.Name -eq $name) { $known = $true } }
        if (-not $known) {
            Write-Error "unknown CLI '$name' (expected one of: claude, codex, opencode, pi)"
            exit 1
        }
        if ($selected -contains $name) { Write-Error "'$name' named twice"; exit 1 }
        $selected += $name
        if ($wanted.Length -gt 0) { $pins[$name] = $wanted }
    }
    if ($selected.Count -eq 0) { foreach ($entry in $Catalog) { $selected += $entry.Name } }

    if (-not (Test-Path -LiteralPath $Dockerfile)) {
        Write-Error "no such file: $Dockerfile"
        exit 1
    }
    $content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Dockerfile))

    function Get-PinnedVersion([string]$argName, [string]$text) {
        $match = [regex]::Match($text, ('(?m)^ARG {0}=(.*)$' -f [regex]::Escape($argName)))
        if ($match.Success) { return $match.Groups[1].Value.Trim() }
        return ""
    }

    function Get-PublishedVersion([string]$package) {
        try {
            $encoded = $package.Replace("/", "%2f")
            $answer = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 `
                -Uri ("https://registry.npmjs.org/{0}/latest" -f $encoded)
            return [string]$answer.version
        } catch {
            return ""
        }
    }

    function Test-VersionExists([string]$package, [string]$version) {
        try {
            $encoded = $package.Replace("/", "%2f")
            Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 `
                -Uri ("https://registry.npmjs.org/{0}/{1}" -f $encoded, $version) | Out-Null
            return $true
        } catch {
            return $false
        }
    }

    "{0,-10} {1,-32} {2,-12} {3,-12}" -f "CLI", "PACKAGE", "PINNED", "TARGET" | Write-Host
    $changes = @()
    $failures = @()
    foreach ($entry in $Catalog) {
        if (-not ($selected -contains $entry.Name)) { continue }
        $current = Get-PinnedVersion $entry.Arg $content
        if ($current.Length -eq 0) {
            Write-Error ("{0} is not pinned in {1} - refusing to guess" -f $entry.Arg, $Dockerfile)
            exit 1
        }

        $note = "published"
        if ($pins.ContainsKey($entry.Name)) {
            $target = $pins[$entry.Name]
            $note = "requested"
            if (-not (Test-VersionExists $entry.Package $target)) {
                "{0,-10} {1,-32} {2,-12} {3,-12} NOT IN REGISTRY" -f `
                    $entry.Name, $entry.Package, $current, $target | Write-Host
                $failures += $entry.Name
                continue
            }
        } else {
            $target = Get-PublishedVersion $entry.Package
            if ($target.Length -eq 0) {
                "{0,-10} {1,-32} {2,-12} {3,-12} LOOKUP FAILED" -f `
                    $entry.Name, $entry.Package, $current, "?" | Write-Host
                $failures += $entry.Name
                continue
            }
        }

        if ($current -eq $target) {
            "{0,-10} {1,-32} {2,-12} {3,-12} up to date" -f `
                $entry.Name, $entry.Package, $current, $target | Write-Host
        } else {
            "{0,-10} {1,-32} {2,-12} {3,-12} -> {4}" -f `
                $entry.Name, $entry.Package, $current, $target, $note | Write-Host
            $changes += @{ Arg = $entry.Arg; Version = $target }
        }
    }

    # A lookup we could not complete is not evidence that a pin is current. Fail closed.
    if ($failures.Count -gt 0) {
        Write-Error ("could not resolve: {0} - nothing was written" -f ($failures -join ", "))
        exit 1
    }

    if ($changes.Count -eq 0) {
        Write-Host ""
        Write-Host "Every selected pin is already current. Nothing to do."
        exit 0
    }

    if (-not $Apply) {
        Write-Host ""
        Write-Host "Report only - $Dockerfile is unchanged. Re-run with -Apply to move these pins."
        exit 0
    }

    # Rewrite only the exact 'ARG NAME=' lines resolved above. Every other pin in the file - the base
    # image digest, ttyd, npm, Herdr, Bun, Playwright, the AWS CLI and the Docker clients - is left
    # alone, as are ALLOW_TOOL_UPGRADES and the disabled runtime self-updater.
    foreach ($change in $changes) {
        $pattern = '(?m)^ARG {0}=.*$' -f [regex]::Escape($change.Arg)
        if ([regex]::Matches($content, $pattern).Count -ne 1) {
            Write-Error ("refusing to edit {0}: expected exactly one 'ARG {1}=' line" -f $Dockerfile, $change.Arg)
            exit 1
        }
        $content = [regex]::Replace($content, $pattern, ("ARG {0}={1}" -f $change.Arg, $change.Version))
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Dockerfile), $content, $utf8NoBom)

    Write-Host ""
    Write-Host "Updated ${Dockerfile}:"
    foreach ($change in $changes) { Write-Host ("  ARG {0}={1}" -f $change.Arg, $change.Version) }
    Write-Host ""
    Write-Host "Review the diff, then rebuild - the rebuild is deliberately a separate step:"
    Write-Host ""
    Write-Host "  git diff Dockerfile"
    Write-Host "  .\run.ps1"
} finally {
    Pop-Location
}
