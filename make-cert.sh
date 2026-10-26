#!/bin/bash
# Creates a local self-signed code-signing identity "Nook Local Signing" in the login keychain.
# With it, install.sh signs Nook the same way every build, so macOS keeps granted permissions
# (Accessibility, Full Disk Access, Calendar…) across rebuilds. Run once.
set -euo pipefail
NAME="Nook Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "Already exists: $NAME"; exit 0; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cs.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cs.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/nook.p12" -passout pass:nook 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/nook.p12" -passout pass:nook
security import "$TMP/nook.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P nook -T /usr/bin/codesign
# Trust it for code signing (macOS asks for your password once).
security add-trusted-cert -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"
security find-identity -p codesigning | grep "$NAME"
