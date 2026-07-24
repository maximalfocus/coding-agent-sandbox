#!/usr/bin/env bash
# Verify issue #31's Maven layer cleanup, final settings, and Trivy secret evidence.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:-coding-agent-sandbox:latest}"
REPORT="${VERIFY_MAVEN_SECRETS_REPORT:-}"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"

fail() { echo "verify-maven-secrets: $*" >&2; exit 1; }

python3 - <<'PY'
from pathlib import Path
import re

text = Path("Dockerfile").read_text(encoding="utf-8")
logical = []
buf = ""
for raw in text.splitlines():
    line = raw.rstrip()
    if not buf and (not line.strip() or line.lstrip().startswith("#")):
        continue
    buf = f"{buf} {line.strip()}".strip()
    if not line.endswith("\\"):
        logical.append(buf)
        buf = ""
if buf:
    raise SystemExit("verify-maven-secrets: unterminated Dockerfile continuation")

install_indexes = []
for index, instruction in enumerate(logical):
    if not instruction.upper().startswith("RUN "):
        continue
    if re.search(r"\bapt-get\s+install\b", instruction) and re.search(r"(?<![-\w])maven(?![-\w])", instruction):
        install_indexes.append(index)
if len(install_indexes) != 1:
    raise SystemExit(f"verify-maven-secrets: expected one Maven-install RUN, found {len(install_indexes)}")
index = install_indexes[0]
run = logical[index]
install_at = run.find("apt-get install")
delete = re.search(r"\brm\s+(?:-[A-Za-z]*f[A-Za-z]*\s+|--force\s+)?/etc/maven/settings\.xml\b", run)
if delete is None or delete.start() <= install_at:
    raise SystemExit("verify-maven-secrets: package settings must be deleted after install in the same RUN")
copy_indexes = [
    i for i, instruction in enumerate(logical)
    if re.fullmatch(r"COPY\s+maven-settings\.xml\s+/etc/maven/settings\.xml", instruction, re.IGNORECASE)
]
if len(copy_indexes) != 1 or copy_indexes[0] <= index:
    raise SystemExit("verify-maven-secrets: project Maven settings must be copied exactly once after cleanup")

for path in Path(".").glob(".trivyignore*"):
    if path.is_file():
        raise SystemExit(f"verify-maven-secrets: scanner suppression is forbidden: {path}")
for path in (Path("trivy-secret.yaml"), Path("trivy.yaml"), Path(".trivy.yaml")):
    if path.exists():
        raise SystemExit(f"verify-maven-secrets: scanner suppression/config is forbidden for this fix: {path}")
for path in (Path("scan.sh"), Path("scan.ps1")):
    body = path.read_text(encoding="utf-8")
    if re.search(r"--(?:skip-files|ignorefile|ignore-policy)\b", body, re.IGNORECASE):
        raise SystemExit(f"verify-maven-secrets: broad Trivy suppression flag found in {path}")
print("maven-layer-cleanup: green")
PY

[ -n "${VERIFY_MAVEN_SECRETS_STRUCTURE_ONLY:-}" ] && exit 0

command -v docker >/dev/null || fail "docker is required"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image not found: $IMAGE"

repo_settings="$(mktemp)"
image_settings="$(mktemp)"
tarball=""
owned_report=0
cleanup() {
  rm -f "$repo_settings" "$image_settings"
  [ "$owned_report" = 1 ] && rm -f "$REPORT"
  [ -n "$tarball" ] && rm -f "$tarball"
}
trap cleanup EXIT
cp maven-settings.xml "$repo_settings"
docker run --rm --entrypoint cat "$IMAGE" /etc/maven/settings.xml >"$image_settings"
cmp -s "$repo_settings" "$image_settings" || fail "image Maven settings differ from maven-settings.xml"
python3 - "$image_settings" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except (OSError, ET.ParseError) as exc:
    raise SystemExit(f"verify-maven-secrets: invalid final Maven settings XML: {exc}")
names = {node.tag.rsplit("}", 1)[-1].lower() for node in root.iter()}
for forbidden in ("password", "passphrase"):
    if forbidden in names:
        raise SystemExit(f"verify-maven-secrets: final settings contain <{forbidden}>")
proxies = [node for node in root.iter() if node.tag.rsplit("}", 1)[-1] == "proxy"]
if len(proxies) != 1:
    raise SystemExit(f"verify-maven-secrets: expected one project proxy, found {len(proxies)}")
values = {child.tag.rsplit("}", 1)[-1]: (child.text or "").strip() for child in proxies[0]}
if values.get("host") != "127.0.0.1" or values.get("port") != "8888" or values.get("active") != "true":
    raise SystemExit("verify-maven-secrets: final Maven proxy is not the active sandbox proxy")
print("maven-final-settings: green")
PY

if [ -z "$REPORT" ]; then
  REPORT="$(mktemp)"; owned_report=1
  if command -v trivy >/dev/null 2>&1; then
    trivy image --scanners secret --format json --no-progress "$IMAGE" >"$REPORT"
  else
    tarball="$(mktemp -t sandbox-maven-secrets.XXXXXX.tar)"
    docker save "$IMAGE" -o "$tarball"
    docker run --rm -v "$tarball:/image.tar:ro" \
      -v coding-agent-sandbox-trivy-cache:/root/.cache/trivy \
      "$TRIVY_IMAGE" image --scanners secret --format json --no-progress \
      --input /image.tar >"$REPORT"
  fi
fi
[ -s "$REPORT" ] || fail "Trivy report is missing or empty"
image_diffids="$(docker image inspect --format='{{json .RootFS.Layers}}' "$IMAGE")"
python3 - "$REPORT" "$IMAGE" "$image_diffids" <<'PY'
import json
import sys

path, image, image_diffids_json = sys.argv[1:]
try:
    image_diffids = json.loads(image_diffids_json)
except json.JSONDecodeError as exc:
    raise SystemExit(f"verify-maven-secrets: cannot decode inspected image layers: {exc}")
try:
    with open(path, encoding="utf-8") as stream:
        report = json.load(stream)
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"verify-maven-secrets: malformed Trivy JSON: {exc}")
if not isinstance(report, dict) or report.get("ArtifactType") != "container_image":
    raise SystemExit("verify-maven-secrets: report is not a container-image scan")
results = report.get("Results")
if not isinstance(results, list) or not results:
    raise SystemExit("verify-maven-secrets: empty Trivy scan cannot pass as secret absence")
metadata = report.get("Metadata")
if not isinstance(metadata, dict) or metadata.get("DiffIDs") != image_diffids:
    raise SystemExit("verify-maven-secrets: Trivy report does not match the inspected image layers")
repo_tags = metadata.get("RepoTags")
if not isinstance(repo_tags, list) or image not in repo_tags:
    raise SystemExit("verify-maven-secrets: Trivy report does not identify the requested image tag")

blocked = {"maven-settings-password", "maven-settings-passphrase"}
found = []
for result in results:
    if not isinstance(result, dict):
        raise SystemExit("verify-maven-secrets: malformed Trivy result entry")
    secrets = result.get("Secrets")
    if secrets is None:
        continue
    if not isinstance(secrets, list):
        raise SystemExit("verify-maven-secrets: malformed Secrets field")
    target = str(result.get("Target", "")).lstrip("/")
    for secret in secrets:
        if not isinstance(secret, dict) or not isinstance(secret.get("RuleID"), str):
            raise SystemExit("verify-maven-secrets: malformed secret entry")
        if target == "etc/maven/settings.xml" and secret["RuleID"] in blocked:
            found.append(secret["RuleID"])
if found:
    raise SystemExit("verify-maven-secrets: Maven sample credentials remain: " + ", ".join(sorted(found)))
print("maven-secret-findings: absent")
PY
