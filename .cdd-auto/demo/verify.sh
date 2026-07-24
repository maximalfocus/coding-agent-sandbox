#!/usr/bin/env bash
# Issue #33 acceptance: deterministic contract + built-image + state-boundary proof.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${AWS_DEMO_IMAGE:-coding-agent-sandbox:issue33}
EXPECTED=${EXPECTED_OUTPUT:-$ROOT/.cdd-auto/demo/expected-output.txt}
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

summary=$($ROOT/scripts/test-aws-sso-support.sh | tail -1)
passes=$(printf '%s' "$summary" | sed -n 's/^# pass=\([0-9][0-9]*\) fail=0$/\1/p')
[ "$passes" = 47 ]
printf 'conformance=%s/%s\n' "$passes" "$passes" >> "$TMP"

version=$(docker run --rm --entrypoint aws "$IMAGE" --version 2>&1 | sed -n 's/^aws-cli\/\([^ ]*\).*/\1/p')
[ "$version" = 2.36.7 ]
printf 'aws_cli=%s\n' "$version" >> "$TMP"

regions=$($ROOT/scripts/network/aws-sso-domains.sh us-east-1 | paste -sd, -)
printf 'regions=%s\n' "$regions" >> "$TMP"
if $ROOT/scripts/network/aws-sso-domains.sh 'us-east-1,' >/dev/null 2>&1; then exit 1; fi
printf 'invalid_trailing_comma=denied\n' >> "$TMP"
if $ROOT/scripts/network/aws-sso-domains.sh 'amazonaws.com' >/dev/null 2>&1; then exit 1; fi
printf 'invalid_global_domain=denied\n' >> "$TMP"

python3 - "$ROOT" >> "$TMP" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
cases = [
 ('docker-compose.aws.yml','volume_default','claude-sandbox'),
 ('docker-compose.mitm.aws.yml','volume_mitm','claude-sandbox-mitm'),
 ('docker-compose.sidecar.aws.yml','volume_sidecar','claude-sandbox-node'),
]
for f, label, service in cases:
    d=yaml.safe_load((root/f).read_text())
    assert set(d['services']) == {service}
    assert d['services'][service]['volumes'] == ['claude-aws:/home/node/.aws']
    assert d['volumes']['claude-aws']['name'] == 'coding-agent-sandbox-aws'
    print(f'{label}={service}')
side=yaml.safe_load((root/'docker-compose.sidecar.aws.yml').read_text())
assert 'claude-sandbox-egress' not in side['services']
print('sidecar_egress_mount=absent')
PY
printf 'result=PASS\n' >> "$TMP"

diff -u "$EXPECTED" "$TMP"
cat "$TMP"
