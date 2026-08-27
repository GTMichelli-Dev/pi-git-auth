#!/usr/bin/env bash
# michelli-github-app-token.sh — mint an installation access token for the
# Michelli GitHub App and print it to stdout. Cached per-UID in /tmp so
# back-to-back `git pull`s reuse the same token until it nears expiry.
#
# Config sources (first match wins):
#   - env: MICHELLI_GH_APP_CONF / MICHELLI_GH_APP_PEM / MICHELLI_GH_TOKEN_CACHE
#   - file: /etc/michelli/github-app.conf  (CLIENT_ID=... APP_ID=... INSTALL_ID=...)
#   - file: /etc/michelli/github-app.pem   (the App's PEM private key)
#
# Requires: openssl, curl, jq, base64 (coreutils). The setup script
# `setup-pi-github-app.sh` apt-installs jq + curl if missing.

set -euo pipefail

CONF="${MICHELLI_GH_APP_CONF:-/etc/michelli/github-app.conf}"
PEM="${MICHELLI_GH_APP_PEM:-/etc/michelli/github-app.pem}"
CACHE="${MICHELLI_GH_TOKEN_CACHE:-/tmp/michelli-gh-token-$(id -u)}"

if [[ ! -r "$CONF" ]]; then
  echo "michelli-github-app-token: cannot read $CONF — run setup-pi-github-app.sh first" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$CONF"
# GitHub accepts either the App's numeric App ID or the App's Client ID (the
# newer recommendation) as the JWT `iss` claim. Take whichever is set.
ISSUER="${CLIENT_ID:-${APP_ID:-}}"
: "${ISSUER:?CLIENT_ID (or APP_ID) missing in $CONF}"
: "${INSTALL_ID:?INSTALL_ID missing in $CONF}"

if [[ ! -r "$PEM" ]]; then
  echo "michelli-github-app-token: cannot read $PEM (need read for current user)" >&2
  exit 1
fi

# Reuse cached token if still valid (with 60s headroom).
if [[ -f "$CACHE" ]]; then
  EXP=$(awk -F= '$1=="exp"{print $2}' "$CACHE" 2>/dev/null || true)
  TOK=$(awk -F= '$1=="token"{print $2}' "$CACHE" 2>/dev/null || true)
  if [[ -n "$EXP" && -n "$TOK" && "$EXP" -gt "$(($(date +%s) + 60))" ]]; then
    printf '%s\n' "$TOK"
    exit 0
  fi
fi

b64url() { base64 -w0 | tr -d '=' | tr '/+' '_-'; }

NOW=$(date +%s)
JWT_EXP=$((NOW + 540))   # max 600s; 540 leaves margin for clock skew
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$NOW" "$JWT_EXP" "$ISSUER" | b64url)
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -sign "$PEM" | b64url)
JWT="$HEADER.$PAYLOAD.$SIG"

RESP=$(curl -sS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/$INSTALL_ID/access_tokens")

TOKEN=$(printf '%s' "$RESP" | jq -r '.token // empty')
EXPIRES_AT=$(printf '%s' "$RESP" | jq -r '.expires_at // empty')

if [[ -z "$TOKEN" ]]; then
  echo "michelli-github-app-token: token mint failed. GitHub said:" >&2
  printf '%s\n' "$RESP" >&2
  exit 1
fi

EXP_EPOCH=$(date -d "$EXPIRES_AT" +%s)
umask 077
printf 'token=%s\nexp=%s\n' "$TOKEN" "$EXP_EPOCH" > "$CACHE"
printf '%s\n' "$TOKEN"
