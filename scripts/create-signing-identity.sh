#!/bin/bash
# Creates a local code-signing identity for Agent Desktop.
set -euo pipefail
name="${1:-Agent Desktop Local}"
if security find-identity -p codesigning | grep -qF "\"$name\""; then
  echo "\"$name\" already exists in your keychain."; exit 0
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/signing-identity.XXXXXX")"
# The private key only ever exists here and in the keychain.
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
password="$(openssl rand -hex 16)"
# macOS imports only the older PKCS#12 encryption, not OpenSSL 3's AES default.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -out "$work/identity.p12" \
  -passout "pass:$password" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
# -T lets codesign use the key without a keychain prompt on every build.
security import "$work/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$password" -T /usr/bin/codesign >/dev/null
security find-identity -p codesigning | grep -F "\"$name\"" >/dev/null || { echo 'Import failed.' >&2; exit 1; }
echo "Created \"$name\" (valid until $(date -v+10y +%Y-%m-%d)). It is self-signed, so macOS lists it as not trusted; codesign still uses it."
