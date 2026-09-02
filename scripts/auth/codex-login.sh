#!/usr/bin/env bash
# Log in to the bundled Codex CLI with your personal ChatGPT/OpenAI subscription, from inside the
# sandbox — used for the cross-vendor peer-review loop.
#
# Uses the DEVICE-AUTH flow, which Codex itself recommends for headless/containerized machines:
# it prints a URL + code, you authorize in any browser, and Codex polls OpenAI (through the egress
# proxy) to finish. No localhost:1455 loopback callback — that flow is unreliable through Docker.
# The login is saved in the persisted claude-codex volume, so you only do this once.
#
#   ./scripts/auth/codex-login.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=./auth-common.sh
. "$(dirname "$0")/auth-common.sh"

SVC=$AUTH_SERVICE
row=$(auth_row codex)

auth_require_stack
auth_require_gate "$row"

cat <<'EOF'

Starting `codex login --device-auth`. Codex will print a URL and a short code:
  1. Open the URL in your browser on this laptop.
  2. Enter the code and sign in with your ChatGPT / OpenAI subscription.
  3. Codex polls to finish — the terminal will say it's logged in.

Saved in the persisted codex volume, so you only do this once. Ctrl-C to abort.

EOF

# Run as `node` so the login lands in /home/node/.codex (the persisted volume) and matches the
# user that runs `codex` in the web terminal. Not `exec`: the custody disclosure below is part of
# what this command owes the operator, and an exec'd process never returns to print it.
docker compose exec -u node "$SVC" codex login --device-auth

auth_disclose "$row"
