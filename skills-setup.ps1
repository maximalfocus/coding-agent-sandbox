# Clone (or update) your skill repos INTO the sandbox and load Claude's skills from those live git
# clones — so /cdd, /peer-review work AND their *-evolve commands can commit/push to GitHub.
# Windows counterpart of skills-setup.sh. Repos persist in the claude-config volume; re-run to pull.
#   powershell -ExecutionPolicy Bypass -File .\skills-setup.ps1
#   ...or pass URLs:  .\skills-setup.ps1 https://github.com/you/x-skills.git
param([string[]]$Repos)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot
$svc = "claude-sandbox"

$running = docker compose ps --status running --format '{{.Name}}' 2>$null
if (-not $running) { Write-Host "Sandbox isn't running. Start it first:  start-sandbox.cmd"; exit 1 }

if (-not $Repos -or $Repos.Count -eq 0) {
    $line = Select-String -Path .env -Pattern '^SKILL_REPOS=' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($line) {
        $val = ($line.Line -replace '^SKILL_REPOS=', '').Trim().Trim('"')
        $Repos = $val -split '\s+' | Where-Object { $_ -ne '' }
    }
}
if (-not $Repos -or $Repos.Count -eq 0) {
    Write-Host "No repos given. Set SKILL_REPOS in .env (space-separated HTTPS URLs) or pass them as args."; exit 1
}

# Same per-repo routine as skills-setup.sh, run in-container as node.
$routine = @'
set -e
url="$1"; name="$(basename "$url" .git)"
base="$HOME/.claude/skill-repos"; mkdir -p "$base" "$HOME/.claude/skills"
if [ -d "$base/$name/.git" ]; then
  echo "  updating $name"; git -C "$base/$name" pull --ff-only || echo "  (pull skipped)"
else
  echo "  cloning $name"; git clone "$url" "$base/$name"
fi
n=0
for sk in "$base/$name"/skills/*/; do
  [ -f "${sk}SKILL.md" ] || continue
  tgt="$HOME/.claude/skills/$(basename "${sk%/}")"
  rm -rf "$tgt"; ln -s "${sk%/}" "$tgt"; n=$((n+1))
done
echo "  linked $n skills from $name (live git clone)"
'@

foreach ($url in $Repos) {
    Write-Host "=== $url ==="
    docker compose exec -T -u node $svc sh -c $routine _ $url
}

Write-Host ""
Write-Host "Done. Restart 'claude' in the sandbox to load them. /cdd-evolve & /peerreview-evolve can commit + push."
