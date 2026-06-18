#!/usr/bin/env bash
# Log in to the bundled Codex CLI with your personal ChatGPT/OpenAI subscription, from inside
# the sandbox — used for the cross-vendor peer-review loop.
#
# Why a helper: Codex's "Sign in with ChatGPT" runs an OAuth callback server on 127.0.0.1:1455
# INSIDE the container, but your browser redirects to localhost:1455 on THIS host. They don't
# meet on their own. This bridges them: a socat listener on the container's published port
# (11455) forwards to codex's loopback 1455, and docker-compose publishes host 127.0.0.1:1455 ->
# container 11455. So the browser redirect reaches codex and the login completes.
#
#   ./codex-login.sh        # one-time; the login then persists in the claude-codex volume
set -euo pipefail
cd "$(dirname "$0")"

SVC=claude-sandbox
if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi

# Token exchange goes through the egress proxy, so OpenAI must be allowlisted or it 403s.
# Make it permanent by setting ALLOW_OPENAI=true in .env; this covers the current session too.
echo "Allowlisting OpenAI domains for this session..."
./allow-domain.sh openai.com chatgpt.com >/dev/null

# Bridge the callback: socat on 0.0.0.0:11455 -> codex's loopback 1455. Idempotent.
# `pgrep -x socat` matches the socat process by name (not `pgrep -f`, which would self-match the
# guard command line, since it contains the word "socat" — then socat would never start).
docker compose exec -d "$SVC" sh -c \
    'pgrep -x socat >/dev/null 2>&1 || socat TCP-LISTEN:11455,fork,reuseaddr TCP:127.0.0.1:1455'

cat <<'EOF'

Starting `codex login`. When it prints a URL:
  1. Open it in your browser on this laptop.
  2. Sign in with your ChatGPT / OpenAI subscription.
  3. It redirects to http://localhost:1455/... and the CLI completes the login.

The login is saved in the persisted claude-codex volume, so you only do this once.
If the browser shows "can't reach this page" at localhost:1455, see the access-token
fallback in the README. Press Ctrl-C to abort.

EOF

exec docker compose exec "$SVC" codex login
