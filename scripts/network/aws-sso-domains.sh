#!/usr/bin/env bash
# Convert opt-in AWS IAM Identity Center regions into the exact required egress hosts.
set -euo pipefail

regions=${1-}
[ -n "$regions" ] || { echo 'AWS_SSO_REGIONS must not be empty' >&2; exit 2; }

IFS=',' read -r -a values <<< "$regions"
[ "${#values[@]}" -gt 0 ] || exit 2
seen=','
for region in "${values[@]}"; do
    # AWS region identifiers are lower-case partition/location/ordinal tokens. Accept Gov/ISO
    # forms without accepting dots, wildcards, hostnames, spaces, or empty comma elements.
    if [[ ! "$region" =~ ^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$ ]]; then
        echo "invalid AWS region in AWS_SSO_REGIONS: '$region'" >&2
        exit 2
    fi
    case "$seen" in *",$region,"*) echo "duplicate AWS region: '$region'" >&2; exit 2 ;; esac
    seen="${seen}${region},"
    printf 'oidc.%s.amazonaws.com\n' "$region"
    printf 'portal.sso.%s.amazonaws.com\n' "$region"
    printf 'sts.%s.amazonaws.com\n' "$region"
done
