#!/bin/bash
# Creates a local code signing certificate so screen recording permission survives a
# rebuild. Run this once. It needs no Apple Developer account.
set -euo pipefail

NAME="${1:-ClipFarm Local Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "$NAME already exists"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$NAME
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The legacy flag matters. Without it the keychain rejects the bundle's MAC.
openssl pkcs12 -export -legacy -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass:clipfarm 2>/dev/null

security import "$WORK/identity.p12" -k ~/Library/Keychains/login.keychain-db \
  -P clipfarm -T /usr/bin/codesign -A >/dev/null

# codesign only accepts a certificate the keychain trusts for signing.
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db \
  "$WORK/cert.pem" >/dev/null

echo "Created $NAME"
security find-identity -v -p codesigning | grep "$NAME"
