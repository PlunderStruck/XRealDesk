#!/bin/bash
# Creates a local self-signed code-signing identity ("XRealDesk Local Signing") in your login keychain.
# Why: macOS ties the Screen Recording permission to the app's signature. Ad-hoc signatures change on
# every build, which would make you re-grant permission after each rebuild. A stable local identity fixes that.
set -euo pipefail
NAME="XRealDesk Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists."; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:xrealdesk 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:xrealdesk
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P xrealdesk -T /usr/bin/codesign >/dev/null
echo "Created identity '$NAME'."
