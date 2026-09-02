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
        @{ Name = "pi";       Arg = "PI_VERSION";          Package = "@earendil-works/pi-coding-agent" },
        @{ Name = "herdr";    Arg = "HERDR_VERSION";       Package = "github:herdrdev/herdr" }
    )
    # The canonical Herdr repository. 'ogulcancelik/herdr' resolves here only through GitHub's
    # rename redirect, which this project does not control.
    $HerdrRepo = "herdrdev/herdr"

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
            Write-Error "unknown CLI '$name' (expected one of: claude, codex, pi, herdr)"
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

    function Get-PublishedVersion([string]$name, [string]$package) {
        try {
            if ($name -eq "herdr") {
                # Resolve through the releases/latest redirect rather than the API: no token, and no
                # unauthenticated rate limit to trip over. The final URL ends in /tag/vX.Y.Z.
                $answer = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 `
                    -Uri ("https://github.com/{0}/releases/latest" -f $HerdrRepo)
                $final = [string]$answer.BaseResponse.ResponseUri.AbsoluteUri
                $marker = "/tag/"
                if ($final.Contains($marker)) {
                    $tag = $final.Substring($final.IndexOf($marker) + $marker.Length)
                    if ($tag.StartsWith("v")) { $tag = $tag.Substring(1) }
                    return $tag
                }
                return ""
            }
            $encoded = $package.Replace("/", "%2f")
            $answer = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 `
                -Uri ("https://registry.npmjs.org/{0}/latest" -f $encoded)
            return [string]$answer.version
        } catch {
            return ""
        }
    }

    function Test-VersionExists([string]$name, [string]$package, [string]$version) {
        try {
            if ($name -eq "herdr") {
                Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Method Head `
                    -Uri ("https://github.com/{0}/releases/tag/v{1}" -f $HerdrRepo, $version) | Out-Null
                return $true
            }
            $encoded = $package.Replace("/", "%2f")
            Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 `
                -Uri ("https://registry.npmjs.org/{0}/{1}" -f $encoded, $version) | Out-Null
            return $true
        } catch {
            return $false
        }
    }

    # sha256 DERIVED from the artifact actually downloaded. Never accepts a checksum from an
    # argument: a pin you were handed proves nothing.
    function Get-HerdrChecksum([string]$version, [string]$arch) {
        $target = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 `
                -Uri ("https://github.com/{0}/releases/download/v{1}/herdr-linux-{2}" -f $HerdrRepo, $version, $arch) `
                -OutFile $target
        } catch {
            Write-Error ("could not download herdr {0} for {1} - nothing was written" -f $version, $arch)
            exit 1
        }
        # A truncated transfer or an error page must not be hashed and recorded as a pin. The real
        # binaries are about 20MB; anything tiny is not one.
        $size = (Get-Item -LiteralPath $target).Length
        if ($size -lt 1000000) {
            Remove-Item -LiteralPath $target -Force
            Write-Error ("herdr {0} {1} download was only {2} bytes - refusing to pin it" -f $version, $arch, $size)
            exit 1
        }
        $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
        Remove-Item -LiteralPath $target -Force
        return $hash
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
            if (-not (Test-VersionExists $entry.Name $entry.Package $target)) {
                "{0,-10} {1,-32} {2,-12} {3,-12} NOT IN REGISTRY" -f `
                    $entry.Name, $entry.Package, $current, $target | Write-Host
                $failures += $entry.Name
                continue
            }
        } else {
            $target = Get-PublishedVersion $entry.Name $entry.Package
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

    # --- what does moving these pins cost? --------------------------------------------------
    # A pin move is a rebuild AND a revalidation. docs/pin-acceptance.md records which verification
    # rests on each component's runtime behaviour; an unmapped pin is refused here rather than moved
    # silently. The POSIX twin resolves this through check-pin-acceptance.sh; that is a shell script,
    # so this reads the same inventory block directly. Only the LOOKUP is duplicated - every
    # validation rule (field count, rerun agreement, none-requires-a-note) stays in the checker,
    # which the repository check set runs on every change regardless of platform.
    $inventoryPath = Join-Path (Split-Path -Parent $Dockerfile) "docs/pin-acceptance.md"
    if (-not (Test-Path $inventoryPath)) {
        $inventoryPath = Join-Path $PSScriptRoot "../docs/pin-acceptance.md"
    }
    if (-not (Test-Path $inventoryPath)) {
        Write-Error "missing docs/pin-acceptance.md - cannot resolve what these pins carry"
        exit 1
    }

    $rows = @()
    $inBlock = $false
    foreach ($line in (Get-Content -LiteralPath $inventoryPath)) {
        if ($line -eq '```pin-acceptance') { $inBlock = $true; continue }
        if ($inBlock -and $line.StartsWith('```')) { $inBlock = $false; continue }
        if (-not $inBlock) { continue }
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        $f = $trimmed -split '\|'
        if ($f.Count -ne 7) { continue }
        $pin = $f[3].Trim()
        if (-not $pin.StartsWith("ARG ")) { continue }
        $rows += @{
            Arg          = ($pin.Substring(4) -split '=')[0]
            Verification = $f[4].Trim()
            Rerun        = $f[5].Trim()
            Note         = $f[6].Trim()
        }
    }

    # Every ARG this run could write, including the checksums a herdr move brings with it.
    $writableArgs = @()
    foreach ($change in $changes) {
        $writableArgs += $change.Arg
        if ($change.Arg -eq "HERDR_VERSION") {
            $writableArgs += "HERDR_SHA256_AMD64"
            $writableArgs += "HERDR_SHA256_ARM64"
        }
    }

    $unmapped = @()
    $affected = @()
    foreach ($arg in $writableArgs) {
        $row = $null
        foreach ($candidate in $rows) { if ($candidate.Arg -eq $arg) { $row = $candidate; break } }
        if ($null -eq $row) { $unmapped += $arg } else { $affected += $row }
    }

    if ($unmapped.Count -gt 0) {
        Write-Error ("these pins have no row in docs/pin-acceptance.md: {0}" -f ($unmapped -join ", "))
        Write-Error "Record what verification rests on each before moving it. Nothing was written."
        exit 1
    }

    Write-Host ""
    Write-Host "Moving these pins invalidates the verification below. Re-run it after the rebuild:"
    foreach ($row in $affected) {
        Write-Host ("  {0}" -f $row.Arg)
        foreach ($check in ($row.Verification -split ',')) {
            $check = $check.Trim()
            if ($check -eq "") { continue }
            if ($check.StartsWith("operator:")) {
                Write-Host ("      {0}   <- NO AUTOMATED RUN PRODUCES THIS" -f $check)
            } elseif ($check.StartsWith("host:")) {
                Write-Host ("      {0}   <- needs another host class" -f $check)
            } elseif ($check -eq "none") {
                Write-Host ("      (nothing rests on this pin: {0})" -f $row.Note)
            } else {
                Write-Host ("      {0}" -f $check)
            }
        }
        if ($row.Note -ne "-" -and $row.Rerun -ne "none") {
            Write-Host ("      note: {0}" -f $row.Note)
        }
    }

    if (-not $Apply) {
        Write-Host ""
        Write-Host "Report only - $Dockerfile is unchanged. Re-run with -Apply to move these pins."
        exit 0
    }

    # Derive checksums BEFORE touching anything. A version bumped with a stale checksum would fail
    # every later build, so the download has to succeed first or nothing is written at all. This is
    # also why the report never downloads: only an -Apply that actually moves herdr pays for it.
    $extra = @()
    foreach ($change in $changes) {
        if ($change.Arg -ne "HERDR_VERSION") { continue }
        Write-Host ""
        Write-Host ("Downloading herdr {0} to derive its checksums (both architectures, one release)..." -f $change.Version)
        $amd64 = Get-HerdrChecksum $change.Version "x86_64"
        $arm64 = Get-HerdrChecksum $change.Version "aarch64"
        $extra += @{ Arg = "HERDR_SHA256_AMD64"; Version = $amd64 }
        $extra += @{ Arg = "HERDR_SHA256_ARM64"; Version = $arm64 }
        Write-Host ("  x86_64  {0}" -f $amd64)
        Write-Host ("  aarch64 {0}" -f $arm64)
        Write-Host ""
        Write-Host "  These checksums were derived from the bytes just downloaded. They attest WHAT WAS"
        Write-Host "  FETCHED NOW, not upstream intent - there is no published signature to check them"
        Write-Host "  against. What the pin buys is that no later build can be served different bytes"
        Write-Host "  without failing. Review before you rebuild."
    }
    foreach ($item in $extra) { $changes += $item }

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
