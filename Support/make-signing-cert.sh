#!/bin/sh
# Give Marina a stable code identity.
#
# macOS binds file-access permissions (Desktop, Documents, Downloads, …) to the
# app's code signature. An ad-hoc signature — `codesign --sign -` — gets a new
# cdhash on every build, so every rebuild looked like a brand new app: the
# grants were dropped and the prompts came back, or a stale "Don't Allow" stuck.
#
# Signing with the self-signed certificate this script creates makes the
# designated requirement
#
#     identifier "org.fherwig.marina" and certificate root = H"…"
#
# which does not change when the binary does. Grant Marina access once and it
# keeps it. Run this once per machine; `make app` picks the identity up
# automatically and falls back to ad-hoc if it is missing.
#
# Two dialogs will appear: one to unlock the keychain, one to trust the
# certificate for code signing. Both want your login password.
set -e

NAME="Marina Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists — nothing to do."
    exit 0
fi

openssl req -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" \
    -x509 -days 7300 -out "$WORK/cert.pem" \
    -subj "/CN=$NAME/O=Marina/C=CA" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# The legacy PBE algorithms are not a preference: macOS's PKCS#12 reader
# rejects OpenSSL 3's defaults with "MAC verification failed".
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/id.p12" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout pass:marina

security import "$WORK/id.p12" -k "$KEYCHAIN" -P marina \
    -T /usr/bin/codesign -T /usr/bin/security -A

security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" || true
echo
echo "Done. Rebuild with 'make app'; the first launch will ask for folder"
echo "access once — say yes, and it stays granted across future builds."
