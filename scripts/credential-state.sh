#!/usr/bin/env bash
# Classify the agent's Claude credential file into exactly one named state (issue #89).
#
# Reads the credential JSON on stdin and prints one word. It exists as its own script because the
# logic it replaces lived inline in sidecar-smoketest.sh, could not be tested, and consequently was
# not: an `else` branch reported "a real token is still in the agent config" for a file whose tokens
# were empty strings. That reading sent a real investigation down the wrong path, so the states are
# now named and the classification is driven by fixtures.
#
# States:
#   absent       nothing to classify — no login yet, or the file could not be read
#   malformed    there is content, but no accessToken field to reason about
#   placeholder  accessToken is exactly the placeholder: the claim succeeded
#   cleared      no token value is left at all: the CLI erased its own login
#   credential   a token value is present: something real is there to claim
#
# `cleared` requires BOTH tokens to be empty, not just the access token. A file holding an empty
# accessToken beside a real refreshToken is not cleared — claiming can still move that refresh token
# into the vault, and reporting "claiming cannot help" would be the same class of wrong conclusion
# this script exists to stop.
#
# Emptiness is read from the token strings directly. The issue offered `expiresAt` as a discriminator
# too; it isn't needed, because an empty string is direct evidence of absence, whereas an expiry is
# only a proxy for it. Nothing here depends on how long a real token has left to live.
#
# It never prints, logs, or compares a credential by value beyond the placeholder equality test the
# smoke test has always used.
#
# Usage:  cat .credentials.json | scripts/credential-state.sh [placeholder]
set -uo pipefail

PLACEHOLDER=${1:-${TOKEN_PLACEHOLDER:-sandbox-placeholder-do-not-use}}
creds=$(cat)

# Trim whitespace so a file of blank lines is `absent` rather than `malformed`.
trimmed=$(printf '%s' "$creds" | tr -d '[:space:]')
if [ -z "$trimmed" ]; then
    printf 'absent\n'; exit 0
fi

if ! printf '%s' "$creds" | grep -q '"accessToken"'; then
    printf 'malformed\n'; exit 0
fi

# Escape regex metacharacters in the placeholder so an unusual value cannot widen the match.
# This is the smoke test's long-standing pass condition and is deliberately left exactly as strict as
# it has always been: an exact accessToken match, and nothing else, means the claim succeeded.
escaped=$(printf '%s' "$PLACEHOLDER" | sed 's/[][\.*^$(){}?+|/\\]/\\&/g')
if printf '%s' "$creds" | grep -qE "\"accessToken\"[[:space:]]*:[[:space:]]*\"${escaped}\""; then
    printf 'placeholder\n'; exit 0
fi

# Empty means empty everywhere. A non-empty value on either token is something a claim can act on.
empty_field() { # field — true when present and empty, or absent entirely
    printf '%s' "$creds" | grep -qE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]" && return 1
    return 0
}
if empty_field accessToken && empty_field refreshToken; then
    printf 'cleared\n'; exit 0
fi

printf 'credential\n'
