#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/mitm/resolve-sidecar-interfaces"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/getent" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = ahostsv4 ] || exit 64
[ -n "${FAKE_GETENT_OUTPUT:-}" ] || exit 2
printf '%s\n' "$FAKE_GETENT_OUTPUT"
EOF

cat > "$TMP/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    '-o -4 addr show') printf '%s\n' "${FAKE_ADDR_OUTPUT:-}" ;;
    '-o -4 route show default') printf '%s\n' "${FAKE_ROUTE_OUTPUT:-}" ;;
    *) exit 64 ;;
esac
EOF
chmod +x "$TMP/bin/getent" "$TMP/bin/ip"

pass=0
fail=0
ok() { echo "ok - $1"; pass=$((pass + 1)); }
no() { echo "not ok - $1"; fail=$((fail + 1)); }

run_helper() {
    FAKE_GETENT_OUTPUT="$2" FAKE_ADDR_OUTPUT="$3" FAKE_ROUTE_OUTPUT="$4" \
        PATH="$TMP/bin:$PATH" bash "$HELPER" "$1"
}

expect_success() {
    name="$1" expected="$2" alias="$3" getent_output="$4" addr_output="$5" route_output="$6"
    if actual=$(run_helper "$alias" "$getent_output" "$addr_output" "$route_output" 2>"$TMP/err") \
       && [ "$actual" = "$expected" ]; then
        ok "$name"
    else
        no "$name (output='${actual:-}', error='$(tr '\n' ' ' < "$TMP/err")')"
    fi
}

expect_failure() {
    name="$1" error_fragment="$2" alias="$3" getent_output="$4" addr_output="$5" route_output="$6"
    if run_helper "$alias" "$getent_output" "$addr_output" "$route_output" >"$TMP/out" 2>"$TMP/err"; then
        no "$name (unexpected success: $(cat "$TMP/out"))"
    elif grep -Fq "$error_fragment" "$TMP/err"; then
        ok "$name"
    else
        no "$name (wrong error: $(tr '\n' ' ' < "$TMP/err"))"
    fi
}

getent_one=$'172.30.0.2 STREAM sandbox-egress-internal\n172.30.0.2 DGRAM sandbox-egress-internal\n172.30.0.2 RAW sandbox-egress-internal'
addr_two=$'2: eth0    inet 172.29.0.2/16 brd 172.29.255.255 scope global eth0\n3: eth1@if27    inet 172.30.0.2/16 brd 172.30.255.255 scope global eth1'
route_one='default via 172.29.0.1 dev eth0'

expect_success "network alias selects its unique local non-egress interface" \
    "eth1 eth0 172.30.0.2" sandbox-egress-internal "$getent_one" "$addr_two" "$route_one"

expect_failure "missing alias resolution fails closed" "exactly one IPv4" \
    sandbox-egress-internal "" "$addr_two" "$route_one"

expect_failure "multiple alias addresses fail closed" "exactly one IPv4" \
    sandbox-egress-internal $'172.30.0.2 STREAM alias\n172.31.0.2 STREAM alias' "$addr_two" "$route_one"

expect_failure "non-local alias address fails closed" "exactly one local interface" \
    sandbox-egress-internal '172.31.0.2 STREAM alias' "$addr_two" "$route_one"

expect_failure "address present on multiple interfaces fails closed" "exactly one local interface" \
    sandbox-egress-internal "$getent_one" \
    $'2: eth1    inet 172.30.0.2/16 scope global eth1\n3: eth2    inet 172.30.0.2/16 scope global eth2' "$route_one"

expect_failure "multiple default-route interfaces fail closed" "exactly one default-route interface" \
    sandbox-egress-internal "$getent_one" "$addr_two" \
    $'default via 172.29.0.1 dev eth0\ndefault via 192.0.2.1 dev eth2 metric 100'

expect_failure "internal alias may not identify the egress interface" "must differ" \
    sandbox-egress-internal '172.29.0.2 STREAM alias' "$addr_two" "$route_one"

expect_failure "invalid alias value fails before lookup" "invalid internal network alias" \
    'bad alias' "$getent_one" "$addr_two" "$route_one"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
