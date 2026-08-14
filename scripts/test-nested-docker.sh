#!/usr/bin/env bash
# Deterministic coverage for issue #65 (SL-14 / CAS-R130-CAS-R134): nested container builds without
# host daemon exposure. Structural and fail-closed checks only — no container is started here.
# The live boundary (nested build/run and nested egress denial) is exercised separately; see
# README.md, because unit checks cannot prove daemon behavior.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AGENT_ENTRY="$ROOT/mitm/agent-entrypoint.sh"
DIND_ENTRY="$ROOT/mitm/dind-entrypoint.sh"
OVERLAY="$ROOT/docker-compose.dind.yml"
SIDECAR="$ROOT/docker-compose.sidecar.yml"

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[[ -f "$OVERLAY" ]] || fail "overlay is missing"
[[ -x "$DIND_ENTRY" ]] || fail "dind entrypoint is missing or not executable"
ok "overlay and nested-daemon entrypoint are present"

# --- capability gate defaults off and fails closed -------------------------
grep -qx 'ENABLE_NESTED_DOCKER=false' "$ROOT/.env.example" \
    || fail ".env.example must default ENABLE_NESTED_DOCKER to false"
grep -q 'true|1|yes|on) NESTED_DOCKER=true' "$AGENT_ENTRY" \
    || fail "agent entrypoint lost its explicit true-value parsing"
grep -q 'false|0|no|off) ;;' "$AGENT_ENTRY" \
    || fail "agent entrypoint lost its explicit false-value parsing"
grep -q "unrecognized ENABLE_NESTED_DOCKER=.*fail-closed" "$AGENT_ENTRY" \
    || fail "agent entrypoint must reject unrecognized gate values fail-closed"
ok "gate defaults off, parses explicit values, and rejects anything else"

# --- the gate's own parsing behavior, executed rather than asserted --------
gate_result() { # value -> prints on/off, or exits non-zero like the entrypoint would
    ENABLE_NESTED_DOCKER=$1 bash -c '
        case "$(printf "%s" "${ENABLE_NESTED_DOCKER:-false}" | tr "[:upper:]" "[:lower:]")" in
            true|1|yes|on) echo on ;;
            false|0|no|off) echo off ;;
            *) exit 1 ;;
        esac'
}
for v in true 1 yes on TRUE On; do
    [[ "$(gate_result "$v")" == on ]] || fail "gate should be on for '$v'"
done
for v in false 0 no off FALSE Off ""; do
    [[ "$(gate_result "$v")" == off ]] || fail "gate should be off for '$v'"
done
for v in maybe 2 "true " enabled; do
    gate_result "$v" >/dev/null 2>&1 && fail "gate should fail closed for '$v'"
done
ok "gate value parsing is on/off/fail-closed as specified"

# --- port validation cannot reach an iptables argument --------------------
grep -q "NESTED_DOCKER_PORT.*is not a port number" "$AGENT_ENTRY" \
    || fail "agent entrypoint must reject a non-numeric nested-daemon port"
grep -q 'out of range' "$AGENT_ENTRY" \
    || fail "agent entrypoint must range-check the nested-daemon port"
ok "nested-daemon port is validated before it reaches a firewall rule"

# --- firewall rule ordering -----------------------------------------------
# The nested-daemon ACCEPT must precede the RFC1918 REJECT loop, or the daemon (which lives on the
# internal network) would be unreachable and the capability silently broken.
accept_line=$(grep -n 'dport "\$DIND_PORT" -j ACCEPT' "$AGENT_ENTRY" | cut -d: -f1)
reject_line=$(grep -n 'for net in 0.0.0.0/8' "$AGENT_ENTRY" | cut -d: -f1)
[[ -n "$accept_line" && -n "$reject_line" ]] || fail "could not locate firewall rules to order-check"
[[ "$accept_line" -lt "$reject_line" ]] \
    || fail "nested-daemon ACCEPT ($accept_line) must precede the private-range REJECTs ($reject_line)"
grep -q 'if \[ "\$NESTED_DOCKER" = true \]; then' "$AGENT_ENTRY" \
    || fail "the nested-daemon firewall rule must be conditional on the gate"
ok "nested-daemon firewall rule is gate-conditional and correctly ordered"

# --- the daemon refuses a route off the isolated network ------------------
grep -q 'ip -4 route show default' "$DIND_ENTRY" \
    || fail "nested daemon must assert it has no default route"
grep -q 'Refusing to start' "$DIND_ENTRY" \
    || fail "the default-route assertion must be fatal, not a warning"
grep -q 'HTTPS_PROXY' "$DIND_ENTRY" \
    || fail "nested daemon must require a proxy for its own egress"
grep -q 'update-ca-certificates' "$DIND_ENTRY" \
    || fail "nested daemon must install the sidecar CA into its own trust store"
ok "nested daemon asserts no default route, requires a proxy, and trusts the sidecar CA"

# --- registry auth exemption is narrow and opt-in --------------------------
# Registry pulls need their bearer token preserved, but the exemption must never become a
# token-harvesting channel. Found necessary by live testing: without it an allowlisted pull 401s.
SIDECAR_ENTRY="$ROOT/mitm/sidecar-entrypoint.sh"
grep -q 'NESTED_DOCKER_REGISTRY_AUTH_HOSTS' "$SIDECAR_ENTRY" \
    || fail "sidecar must support a scoped registry auth exemption"
grep -q 'first-party credentials keep their own policy' "$SIDECAR_ENTRY" \
    || fail "registry auth exemption must refuse first-party provider hosts"
grep -q 'not on the egress allowlist' "$SIDECAR_ENTRY" \
    || fail "registry auth exemption must require the host to be allowlisted already"
grep -q 'ignoring invalid registry auth host' "$SIDECAR_ENTRY" \
    || fail "registry auth exemption must validate the domain shape"
# AUTH_HOSTS itself must stay sidecar-owned: an externally settable value would bypass all of the
# above. It is assigned, never defaulted from the environment.
grep -qE '^export AUTH_HOSTS="anthropic\.com' "$SIDECAR_ENTRY" \
    || fail "AUTH_HOSTS must remain assigned by the sidecar, not taken from the environment"
# Anchored so it cannot match the NESTED_DOCKER_REGISTRY_AUTH_HOSTS key, and written as an `if`
# so a non-match does not trip `set -e`.
if grep -qE '^[[:space:]]+AUTH_HOSTS:' "$OVERLAY"; then
    fail "the overlay must not set AUTH_HOSTS directly; use the validated variable"
fi
ok "registry auth exemption is validated, allowlist-scoped, and never first-party"

# --- IFS handling: this exact bug broke sidecar startup and bash -n cannot catch it -------
# Line ordering matters: `unset IFS` precedes the exemption block, so reading $IFS there would be
# an unbound-variable failure under `set -u` at runtime.
if awk '/^IFS=.,.; export ALLOWLIST/{seen=1} seen && /OLDIFS=\$IFS/{found=1} END{exit !found}' "$SIDECAR_ENTRY"; then
    fail "registry auth block reads \$IFS after it was unset (set -u runtime failure)"
fi
ok "registry auth block does not read IFS after it is unset"

# --- composed structure ----------------------------------------------------
CONFIG=$(docker compose -f "$SIDECAR" -f "$OVERLAY" config --format json 2>/dev/null) \
    || fail "sidecar + dind overlay does not parse"

COMPOSED_JSON="$CONFIG" python3 - <<'PY' || exit 1
import json, os, sys
c = json.loads(os.environ["COMPOSED_JSON"])
svcs = c["services"]

def die(m):
    print("FAIL: " + m, file=sys.stderr); sys.exit(1)

dind = svcs.get("claude-sandbox-dind") or die("nested daemon service is absent")
agent = svcs.get("claude-sandbox-node") or die("agent service is absent")

# CAS-R130: no host socket anywhere in the composed stack.
for name, s in svcs.items():
    for v in s.get("volumes", []):
        src = v.get("source", "") if isinstance(v, dict) else str(v)
        if "docker.sock" in src:
            die(f"{name} mounts a host Docker socket")

# CAS-R132: the daemon holds no agent credential volume.
FORBIDDEN = ("claude-config", "claude-secret", "deepseek-secret", "coding-agent-sandbox-config",
             "coding-agent-sandbox-secret", "coding-agent-sandbox-deepseek-secret", "/workspace")
for v in dind.get("volumes", []):
    src = v.get("source", "") if isinstance(v, dict) else str(v)
    tgt = v.get("target", "") if isinstance(v, dict) else ""
    for bad in FORBIDDEN:
        if bad in src or bad in tgt:
            die(f"nested daemon must not mount {bad!r}")

# CAS-R131: the daemon joins only the isolated network.
nets = list(dind.get("networks") or {})
if nets != ["internal"]:
    die(f"nested daemon must join only ['internal'], got {nets}")
if not c["networks"]["internal"].get("internal"):
    die("the internal network must be externally isolated")

# CAS-R132: the agent's capability baseline is untouched.
if agent.get("cap_drop") != ["ALL"]:
    die(f"agent cap_drop changed: {agent.get('cap_drop')}")
expected_caps = {"NET_ADMIN", "SETUID", "SETGID", "CHOWN", "DAC_OVERRIDE"}
if set(agent.get("cap_add", [])) != expected_caps:
    die(f"agent cap_add changed: {agent.get('cap_add')}")
if "no-new-privileges:true" not in agent.get("security_opt", []):
    die("agent lost no-new-privileges")
if agent.get("privileged"):
    die("agent must never be privileged")
if agent.get("pid") or agent.get("network_mode", "").startswith("host"):
    die("agent must not share host namespaces")

# The agent's docker CLI must point at the nested daemon, not a socket.
dh = agent.get("environment", {}).get("DOCKER_HOST", "")
if not dh.startswith("tcp://claude-sandbox-dind:"):
    die(f"agent DOCKER_HOST must target the nested daemon, got {dh!r}")
if agent.get("environment", {}).get("ENABLE_NESTED_DOCKER") != "true":
    die("overlay must enable the gate for the agent")

# Regression: the docker CLI honours HTTP_PROXY. Without the daemon in NO_PROXY, every API call is
# sent to the allowlist proxy and refused, which looks like a daemon outage. Found by live testing.
host_only = dh.removeprefix("tcp://").split(":")[0]
for key in ("NO_PROXY", "no_proxy"):
    val = agent.get("environment", {}).get(key, "")
    if host_only not in val:
        die(f"agent {key}={val!r} must exempt the nested daemon host {host_only!r}")

print("ok  composed structure: no host socket, no credential mounts on the daemon,")
print("ok  isolated network only, agent capability baseline intact, DOCKER_HOST pinned")
PY
PASSED=$((PASSED + 2))

# --- stacks that must be unaffected ---------------------------------------
for f in docker-compose.yml docker-compose.mitm.yml docker-compose.sidecar.yml; do
    docker compose -f "$ROOT/$f" config --quiet >/dev/null 2>&1 || fail "$f no longer parses"
    if docker compose -f "$ROOT/$f" config 2>/dev/null | grep -q 'ENABLE_NESTED_DOCKER: *"true"'; then
        fail "$f must not enable nested Docker"
    fi
done
ok "default, mitm, and sidecar stacks parse and do not enable nested Docker"

printf '\nAll %d checks passed.\n' "$PASSED"
