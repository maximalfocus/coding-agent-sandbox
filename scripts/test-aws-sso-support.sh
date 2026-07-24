#!/usr/bin/env bash
# Issue #33 conformance: packaging, state isolation, regional egress, and operator docs.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0
FAIL=0

ok() { printf 'ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"; PASS=$((PASS + 1)); }
not_ok() { printf 'not ok %02d - %s\n' "$((PASS + FAIL + 1))" "$1"; FAIL=$((FAIL + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else not_ok "$name"; fi; }
contains() { grep -Fq -- "$2" "$1"; }
absent() { [ -f "$1" ] && ! grep -Fq -- "$2" "$1"; }
contains_all() { local f=$1; shift; [ -f "$f" ] || return 1; local needle; for needle in "$@"; do grep -Fq -- "$needle" "$f" || return 1; done; }

DOCKERFILE="$ROOT/Dockerfile"
DOC="$ROOT/docs/aws-sso.md"
HELPER="$ROOT/scripts/network/aws-sso-domains.sh"

check 'Dockerfile pins AWS CLI v2.36.7' contains "$DOCKERFILE" 'ARG AWS_CLI_VERSION=2.36.7'
check 'Dockerfile pins official amd64 SHA-256' contains "$DOCKERFILE" 'd641283d37f1a2168457a9f26a20d4e29167652e9ab1719b37114ef1ebe859f4'
check 'Dockerfile pins official arm64 SHA-256' contains "$DOCKERFILE" '85826b67912b44bb45d1e46c6e66f383c14405ee0b2f4686f73bdf949c93bd61'
check 'Dockerfile maps amd64 to x86_64' contains "$DOCKERFILE" 'amd64) AWS_ARCH=x86_64'
check 'Dockerfile maps arm64 to aarch64' contains "$DOCKERFILE" 'arm64) AWS_ARCH=aarch64'
check 'Dockerfile verifies AWS installer before extraction' bash -c "v=\$(grep -in 'aws' '$DOCKERFILE' | grep 'sha256sum -c' | head -1 | cut -d: -f1); u=\$(grep -n 'unzip' '$DOCKERFILE' | grep -i 'aws' | head -1 | cut -d: -f1); [ -n \"\$v\" ] && [ -n \"\$u\" ] && [ \"\$v\" -lt \"\$u\" ]"
check 'Dockerfile installs AWS CLI root-owned' bash -c "a=\$(grep -n 'aws/install' '$DOCKERFILE' | head -1 | cut -d: -f1); [ -n \"\$a\" ] || exit 1; u=\$(grep -n '^USER ' '$DOCKERFILE' | head -1 | cut -d: -f1); [ -z \"\$u\" ] || [ \"\$a\" -lt \"\$u\" ]"

check 'default stack has no AWS mount' absent "$ROOT/docker-compose.yml" '/home/node/.aws'
check 'MITM stack has no AWS mount' absent "$ROOT/docker-compose.mitm.yml" '/home/node/.aws'
check 'sidecar base stack has no AWS mount' absent "$ROOT/docker-compose.sidecar.yml" '/home/node/.aws'

check 'opt-in Compose overlays isolate AWS state to agent services' python3 - "$ROOT" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
cases = [
    ('docker-compose.aws.yml', 'claude-sandbox'),
    ('docker-compose.mitm.aws.yml', 'claude-sandbox-mitm'),
    ('docker-compose.sidecar.aws.yml', 'claude-sandbox-node'),
]
for filename, agent in cases:
    doc = yaml.safe_load((root / filename).read_text())
    services = doc.get('services', {})
    assert set(services) == {agent}, (filename, set(services))
    volumes = services[agent].get('volumes', [])
    assert volumes == ['claude-aws:/home/node/.aws'], (filename, volumes)
    top = doc.get('volumes', {}).get('claude-aws', {})
    assert top.get('name') == 'coding-agent-sandbox-aws', (filename, top)
assert 'claude-sandbox-egress' not in yaml.safe_load((root / 'docker-compose.sidecar.aws.yml').read_text())['services']
PY

check 'regional endpoint helper is executable' test -x "$HELPER"
if [ -x "$HELPER" ]; then
  expected=$'oidc.us-east-1.amazonaws.com\nportal.sso.us-east-1.amazonaws.com\nsts.us-east-1.amazonaws.com'
  if actual=$("$HELPER" us-east-1 2>/dev/null); then check 'one region emits exactly OIDC, portal, and STS hosts' test "$actual" = "$expected"; else not_ok 'one region emits exactly OIDC, portal, and STS hosts'; fi
  expected=$'oidc.us-east-1.amazonaws.com\nportal.sso.us-east-1.amazonaws.com\nsts.us-east-1.amazonaws.com\noidc.eu-west-2.amazonaws.com\nportal.sso.eu-west-2.amazonaws.com\nsts.eu-west-2.amazonaws.com'
  if actual=$("$HELPER" 'us-east-1,eu-west-2' 2>/dev/null); then check 'multiple regions preserve exact deterministic host set' test "$actual" = "$expected"; else not_ok 'multiple regions preserve exact deterministic host set'; fi
  for bad in '' 'amazonaws.com' '*.amazonaws.com' 'us-east-1.example.com' 'US-EAST-1' 'us_east_1' 'us-east-1,,eu-west-2' 'us-east-1,' ',us-east-1' $'us-east-1\nevil.example.com'; do
    if "$HELPER" "$bad" >/dev/null 2>&1; then not_ok "reject invalid AWS_SSO_REGIONS value: ${bad:-empty}"; else ok "reject invalid AWS_SSO_REGIONS value: ${bad:-empty}"; fi
  done
else
  for name in 'one region emits exactly OIDC, portal, and STS hosts' 'multiple regions preserve exact deterministic host set' 'reject invalid AWS_SSO_REGIONS values'; do not_ok "$name"; done
fi
check 'default proxy consumes AWS_SSO_REGIONS through helper' contains_all "$ROOT/entrypoint.sh" 'AWS_SSO_REGIONS' 'aws-sso-domains'
check 'sidecar proxy consumes AWS_SSO_REGIONS through helper' contains_all "$ROOT/mitm/sidecar-entrypoint.sh" 'AWS_SSO_REGIONS' 'aws-sso-domains'
check 'MITM paths preserve SigV4 Authorization only for derived AWS hosts' bash -c "grep -q 'AWS_AUTH_HOSTS' '$ROOT/mitm/entrypoint.sh' && grep -q 'AUTH_HOSTS=.*AWS_AUTH_HOSTS' '$ROOT/mitm/entrypoint.sh' && grep -q 'AUTH_HOSTS=.*aws_auth_hosts' '$ROOT/mitm/sidecar-entrypoint.sh'"

check 'operator guide exists' test -s "$DOC"
for required in \
  'aws configure sso --profile <profile>' \
  'aws configure list-profiles' \
  'aws sso login --profile <profile>' \
  'aws sts get-caller-identity --profile <profile> --no-cli-pager' \
  'aws sso logout' \
  'coding-agent-sandbox-aws' \
  'AWS_SSO_REGIONS' \
  'coding agent can read' \
  'short-lived' \
  'least-privilege' \
  'administrator-role' \
  'never print' \
  'sso/cache' \
  'docker volume rm'; do
  check "guide contains: $required" contains "$DOC" "$required"
done
check 'guide forbids host AWS mount' contains "$DOC" 'Do not mount host `~/.aws`'
check 'guide forbids image-baked credentials' contains "$DOC" 'Do not bake credentials'
check 'guide forbids environment access keys' contains "$DOC" 'Do not use environment access keys'
check 'guide identifies sidecar exclusion' contains "$DOC" 'egress sidecar'

printf '1..%d\n' "$((PASS + FAIL))"
printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
