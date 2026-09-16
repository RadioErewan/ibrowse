#!/usr/bin/env bash
# Buduje token JWT (ES256) do App Store Connect API, samym openssl.
set -euo pipefail
KEY_ID="${1:?Key ID}"; ISSUER="${2:?Issuer ID}"
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
HEADER=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$KEY_ID" | b64)
NOW=$(date +%s); EXP=$((NOW + 600))
PAYLOAD=$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' "$ISSUER" "$NOW" "$EXP" | b64)
# openssl podpisuje w DER; JWT wymaga surowego R||S po 32 bajty.
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" \
  | openssl dgst -sha256 -sign "$KEY" \
  | openssl asn1parse -inform DER \
  | awk -F: '/INTEGER/ {printf "%064s\n", $4}' | tr ' ' '0' \
  | tr -d '\n' | xxd -r -p | b64)
printf '%s.%s.%s\n' "$HEADER" "$PAYLOAD" "$SIG"
