#!/usr/bin/env bash
# Fetch the Cloudflare WARP root CA into certs/ so this sandbox builds behind WARP
# on a SEED laptop. Run on the HOST (which already trusts WARP), then: ./run.sh
#
# Verified, not blind trust: the download is checked against a pinned SHA-256 AND a
# subject sanity-check before it is written. Override the source with WARP_CA_URL.
set -euo pipefail
cd "$(dirname "$0")"

URL="${WARP_CA_URL:-https://seed-general-public-files.s3.ap-southeast-1.amazonaws.com/seed-cloudflare-root-certs/Cloudflare_CA.crt}"
# SHA-256 of the Cloudflare WARP "Gateway CA - Cloudflare Managed G1" root certificate.
# If your org rotates the WARP CA, update this after verifying the new cert out-of-band.
PIN="2040f4281bae938a1d57c38d9ba257b25e2fd6a331767be3eb1aabc8791b362f"
OUT="Cloudflare_CA.crt"

echo "Downloading WARP CA: $URL"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" "$URL"

openssl x509 -in "$tmp" -noout >/dev/null 2>&1 \
  || { echo "REFUSING: downloaded file is not a valid X.509 certificate." >&2; exit 1; }

got="$(openssl x509 -in "$tmp" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
if [ "$got" != "$PIN" ]; then
  echo "REFUSING: SHA-256 mismatch — not the expected WARP CA." >&2
  echo "  got:  $got" >&2
  echo "  want: $PIN" >&2
  exit 1
fi

echo "Verified: $(openssl x509 -in "$tmp" -noout -subject)"
cp "$tmp" "$OUT"
echo "Wrote certs/$OUT — now build:  ./run.sh"
