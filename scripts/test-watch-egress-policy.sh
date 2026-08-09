#!/usr/bin/env bash
# Regression coverage for issue #46's Bash egress-watcher policy.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/network/watch-egress-policy.sh
. "$ROOT/scripts/network/watch-egress-policy.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

check() {
    local expected="$1" host="$2" actual
    actual=$(classify_egress_host "$host")
    if [ "$actual" != "$expected" ]; then
        fail "$host: expected $expected, got $actual"
    fi
}

check review artifactregistry.googleapis.com
check review arbitrary-tenant.googleapis.com
check review us-central1-docker.pkg.dev
check review storage.googleapis.com
check review bucket.storage.googleapis.com
check review drive.google.com
check allow gstatic.com
check allow cdn.playwright.dev
check allow pypi.org
check reject tracker.doubleclick.net
check reject 169.254.169.254
check gray uploads.example.com

grep -Fq '. ./scripts/network/watch-egress-policy.sh' "$ROOT/scripts/network/watch-egress.sh"
grep -Fq 'verdict=$(classify_egress_host "$host")' "$ROOT/scripts/network/watch-egress.sh"
grep -Eq '^[[:space:]]+review\)' "$ROOT/scripts/network/watch-egress.sh"
review_branch=$(sed -n '/^[[:space:]]*review)/,/^[[:space:]]*gray)/p' "$ROOT/scripts/network/watch-egress.sh")
grep -Fq 'left blocked' <<<"$review_branch" || fail 'review branch does not explicitly leave the host blocked'
if grep -Eq 'do_allow|persist_env|claude[[:space:]]+-p' <<<"$review_branch"; then
    fail 'review branch can invoke unattended allow, persistence, or LLM assessment'
fi

echo 'PASS: Bash watcher keeps broad Google API and package-registry namespaces human-review-only'
