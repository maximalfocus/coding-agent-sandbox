#!/usr/bin/env bash
# Secret-free compatibility probe for issue #63's Docker Sandboxes upstream-proxy verdict
# (docs/sbx-upstream-proxy-feasibility.md).
#
# Re-establishes the interface facts the verdict depends on. It makes no network connection,
# creates no sandbox, reads no credential, and prints no secret. It fails closed when a relied-on
# `sbx` surface is absent or has changed, and reports UNVERIFIED — rather than assuming success —
# for checks it cannot reach (for example when `sbx` is not installed).
#
# Note: reading settings starts the local `sandboxd` daemon if it is not already running. That is
# the only side effect; no sandbox is created and no account is required.
#
# Usage:
#   scripts/probe-sbx-upstream-proxy.sh          human-readable
#   scripts/probe-sbx-upstream-proxy.sh --json   machine-readable
#
# Exit status: 0 when no relied-on fact is contradicted (including when checks are UNVERIFIED),
#              1 when a relied-on fact has changed.
set -uo pipefail

SBX_BIN=${SBX_BIN:-sbx}
JSON=0
[[ ${1:-} == --json ]] && JSON=1

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CHANGED=0
RESULTS=()

record() { # status name detail
    RESULTS+=("$1"$'\t'"$2"$'\t'"$3")
    [[ $1 == CHANGED ]] && CHANGED=1
    return 0
}

emit() {
    if [[ $JSON -eq 1 ]]; then
        printf '{\n  "verdictDoc": "docs/sbx-upstream-proxy-feasibility.md",\n  "checks": [\n'
        local first=1 line status name detail
        for line in "${RESULTS[@]}"; do
            IFS=$'\t' read -r status name detail <<<"$line"
            [[ $first -eq 0 ]] && printf ',\n'
            first=0
            printf '    {"status": "%s", "check": "%s", "detail": "%s"}' \
                "$status" "$name" "${detail//\"/\\\"}"
        done
        printf '\n  ],\n  "relianceContradicted": %s\n}\n' \
            "$([[ $CHANGED -eq 1 ]] && echo true || echo false)"
    else
        local line status name detail
        for line in "${RESULTS[@]}"; do
            IFS=$'\t' read -r status name detail <<<"$line"
            printf '%-11s %-34s %s\n' "$status" "$name" "$detail"
        done
        printf '\n'
        if [[ $CHANGED -eq 1 ]]; then
            printf 'RESULT: a relied-on sbx surface has CHANGED — revisit docs/sbx-upstream-proxy-feasibility.md\n'
        else
            printf 'RESULT: no relied-on sbx surface was contradicted\n'
        fi
    fi
}

# --- locate sbx ------------------------------------------------------------
if [[ "$SBX_BIN" == */* ]]; then
    sbx_cmd=$SBX_BIN
    [[ -x "$sbx_cmd" ]] || sbx_cmd=""
else
    sbx_cmd=$(command -v -- "$SBX_BIN" 2>/dev/null) || sbx_cmd=""
fi

if [[ -z "$sbx_cmd" ]]; then
    record UNVERIFIED sbx-present "sbx not on PATH; install to verify (SBX_BIN overrides)"
    record UNVERIFIED upstream-proxy-keys "requires sbx"
    record UNVERIFIED http-proxy-accepted "requires sbx"
    record UNVERIFIED scope-separation "requires sbx"
    record UNVERIFIED no-custom-ca-setting "requires sbx"
    record UNVERIFIED kit-mixin-schema "requires sbx"
    emit
    exit 0
fi

version=$("$sbx_cmd" version 2>&1 | head -1) || version=""
record PASS sbx-present "${version:-version unreadable}"

# --- settings surface ------------------------------------------------------
settings=$("$sbx_cmd" settings list --json 2>/dev/null) || settings=""

if [[ -z "$settings" ]]; then
    record UNVERIFIED upstream-proxy-keys "settings unreadable (daemon or entitlement unavailable)"
    record UNVERIFIED http-proxy-accepted "requires settings"
    record UNVERIFIED scope-separation "requires settings"
    record UNVERIFIED no-custom-ca-setting "requires settings"
else
    keys=$(printf '%s' "$settings" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d if isinstance(d, list) else d.get("settings", d)
print("\n".join(r.get("key", "") for r in rows))
' 2>/dev/null) || keys=""

    missing=""
    for k in proxy proxy.sandbox proxy.daemon no_proxy.sandbox; do
        grep -qx -- "$k" <<<"$keys" || missing="$missing $k"
    done
    if [[ -n "$missing" ]]; then
        record CHANGED upstream-proxy-keys "missing:$missing"
    else
        record PASS upstream-proxy-keys "proxy, proxy.sandbox, proxy.daemon, no_proxy.sandbox present"
    fi

    # The verdict relies on an HTTP CONNECT proxy being an accepted upstream form, so the
    # mediation layer does not have to change proxy mode.
    proxy_desc=$(printf '%s' "$settings" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d if isinstance(d, list) else d.get("settings", d)
print(next((r.get("description", "") for r in rows if r.get("key") == "proxy"), ""))
' 2>/dev/null) || proxy_desc=""

    if grep -q 'HTTP(S)_PROXY' <<<"$proxy_desc" && grep -qi 'url' <<<"$proxy_desc"; then
        record PASS http-proxy-accepted "proxy accepts a URL form and honours HTTP(S)_PROXY"
    else
        record CHANGED http-proxy-accepted "proxy description no longer documents a URL / HTTP(S)_PROXY form"
    fi

    if grep -qx 'proxy.sandbox' <<<"$keys" && grep -qx 'proxy.daemon' <<<"$keys"; then
        record PASS scope-separation "sandbox and daemon upstream scopes are independently settable"
    else
        record CHANGED scope-separation "independent sandbox/daemon scopes are gone"
    fi

    # The documented limitation rests on there being no way to give the sandbox's own proxy a
    # custom trust anchor. If such a setting appears, the limitation may be retired.
    ca_like=$(grep -iE 'cacert|ca_cert|ca\.cert|customca|trustanchor|trusted.*ca|ca.*bundle' <<<"$keys" || true)
    if [[ -n "$ca_like" ]]; then
        record CHANGED no-custom-ca-setting "a CA-trust-like setting appeared: $(tr '\n' ' ' <<<"$ca_like")"
    else
        record PASS no-custom-ca-setting "no custom-CA trust setting (registry limitation still applies)"
    fi
fi

# --- kit mixin schema ------------------------------------------------------
# The verdict relies on kit mixins carrying setup.files plus a root setup.startup command.
kit_dir="$TMP_DIR/kit"
mkdir -p "$kit_dir"
cat >"$kit_dir/spec.yaml" <<'YAML'
schemaVersion: 2
name: probe-shape-check
kind: mixin
setup:
  files:
    - path: /tmp/probe-shape-check.crt
      content: |
        placeholder
      mode: '0644'
  startup:
    - command:
        - sh
        - -c
        - "true"
      user: root
YAML

kit_out=$("$sbx_cmd" kit validate "$kit_dir" 2>&1) || true
if grep -q '^VALID' <<<"$kit_out"; then
    record PASS kit-mixin-schema "mixin setup.files + root setup.startup still validates"
elif grep -qiE 'unknown command|unrecognized|help' <<<"$kit_out"; then
    record UNVERIFIED kit-mixin-schema "kit subcommand unavailable at this version"
else
    record CHANGED kit-mixin-schema "$(head -1 <<<"$kit_out")"
fi

emit
[[ $CHANGED -eq 1 ]] && exit 1
exit 0
