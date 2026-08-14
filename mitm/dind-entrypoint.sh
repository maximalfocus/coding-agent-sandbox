#!/bin/sh
# Nested Docker daemon for the sidecar stack (issue #65, SL-14 / CAS-R130-CAS-R134).
#
# This container holds the elevated privilege a daemon needs, so the agent does not have to: the
# agent keeps cap_drop ALL + no-new-privileges and reaches this daemon only over one pinned TCP
# address:port on the internal network. No host Docker socket is involved anywhere.
#
# Two properties are asserted here rather than assumed, because both are silent failures otherwise:
#
#   1. NO DEFAULT ROUTE. This container must sit only on the `internal: true` network. If it is ever
#      also attached to the egress network, nested containers would inherit a working NAT path and
#      leave without touching the allowlist proxy at all — the exact egress bypass CAS-R131 forbids.
#      A default route is therefore a hard startup failure, not a warning.
#   2. PROXY CONFIGURED. The daemon itself must pull images through the sidecar proxy. Without it the
#      daemon simply cannot reach a registry (there is no route), so this fails closed on its own —
#      but an explicit check produces a usable error instead of an opaque timeout.
set -eu

say() { [ -n "${SANDBOX_QUIET:-}" ] || echo "$@"; }

# 1. Refuse to run with a route off the isolated network.
if ip -4 route show default 2>/dev/null | grep -q .; then
    echo "ERROR: nested Docker daemon has a default route, so it is not confined to the internal" >&2
    echo "       network. Nested containers could bypass the allowlist proxy. Refusing to start." >&2
    echo "       Attach this service only to the 'internal' network." >&2
    exit 1
fi
say "Nested daemon: no default route (confined to the internal network)."

# 2. Require the proxy to be configured for the daemon's own egress (image pulls).
if [ -z "${HTTPS_PROXY:-${https_proxy:-}}" ]; then
    echo "ERROR: nested Docker daemon has no HTTPS_PROXY; it could not reach any registry and" >&2
    echo "       nothing would constrain it if a route appeared. Refusing to start." >&2
    exit 1
fi

# 3. Trust the sidecar's intercept CA. The daemon has its own TLS trust path: installing the CA
#    where the agent trusts it does NOT make the daemon trust it, and a registry pull would fail
#    with an opaque x509 error. (This is the exact failure mode recorded in
#    docs/sbx-upstream-proxy-feasibility.md for a third-party sandbox that could not be fixed
#    because its proxy exposed no custom-CA setting. Here we own both ends, so we fix it.)
CA_SRC="${SIDECAR_CA_PATH:-/etc/mitmproxy-ca/mitmproxy-ca-cert.pem}"
for _ in $(seq 1 100); do [ -s "$CA_SRC" ] && break; sleep 0.2; done
if [ -s "$CA_SRC" ]; then
    mkdir -p /usr/local/share/ca-certificates
    cp "$CA_SRC" /usr/local/share/ca-certificates/sandbox-egress-ca.crt
    update-ca-certificates >/dev/null 2>&1 || true
    say "Nested daemon: trusted the egress sidecar's intercept CA."
else
    echo "WARN: sidecar CA not present at $CA_SRC; image pulls through the intercepting proxy" >&2
    echo "      will fail TLS verification until it appears." >&2
fi

# 4. Hand off to the upstream dind entrypoint. Listening on 0.0.0.0 is scoped by step 1: the only
#    network attached is the isolated one, so this is reachable from the agent and nowhere else.
exec dockerd-entrypoint.sh \
    --host="tcp://0.0.0.0:${NESTED_DOCKER_PORT:-2375}" \
    --host=unix:///var/run/docker.sock \
    "$@"
