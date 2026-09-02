#!/usr/bin/env bash
# Log in to the bundled Claude Code CLI with your Anthropic subscription, FROM THE HOST.
#
# Until now Claude was the one bundled agent with no host-side sign-in: the documented path was to
# open the web terminal, run `claude`, and type `/login` there. That works, but it is the only
# credential in the product an operator has to enter the sandbox to create, and it is the only one
# whose custody tier nothing states.
#
# This runs `claude auth login` — a supported subcommand of the pinned CLI, recorded as
# claude.cli-login-command in docs/provider-contracts.md — inside the container as the `node` user,
# so the credential lands where the web terminal's own login would put it. Running it as root would
# write a root-owned file the agent user cannot read, which is exactly what issue #108 was.
#
#   ./scripts/auth/claude-login.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=./auth-common.sh
. "$(dirname "$0")/auth-common.sh"

SVC=$AUTH_SERVICE
row=$(auth_row claude)

auth_require_stack
auth_require_gate "$row"   # Anthropic egress is always on, so this is a no-op for Claude today

cat <<'EOF'

Starting `claude auth login`. Claude will print a URL and a code:
  1. Open the URL in your browser on this machine.
  2. Approve, and paste the code back if Claude asks for one.
  3. Claude finishes the exchange through the egress proxy.

Saved in the persisted Claude config volume, so you only do this once. Ctrl-C to abort.

EOF

# `docker compose exec` allocates a TTY by default (it has no -i/-t, only -T to turn one off), and
# this flow is interactive. -u node so the credential is owned by the agent user, not root.
docker compose exec -u node "$SVC" claude auth login --claudeai
docker compose exec -T -u node "$SVC" claude auth status

auth_disclose "$row"
