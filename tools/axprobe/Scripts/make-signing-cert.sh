#!/bin/bash
# Creates a STABLE self-signed code-signing identity in the login keychain.
#
# A stable identity is what makes the Accessibility TCC grant survive rebuilds.
# The designated requirement becomes
#     identifier "<bundle id>" and certificate leaf = H"<cert sha1>"
# instead of the ad-hoc `cdhash H"..."`, which changes on every non-identical
# build and silently orphans the grant.
#
# The certificate is deliberately NOT added to the trust store: codesign signs
# with an untrusted leaf without complaint, and `security add-trusted-cert`
# raises a GUI authorization dialog that cannot be answered non-interactively.
set -euo pipefail

CN="${1:-OpenTab Dev Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$CN"; then
  echo "Identity '$CN' already exists."
  security find-identity -p codesigning | grep "$CN"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = ${CN}
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null

# macOS Security.framework cannot read OpenSSL 3's default PKCS#12 MAC
# algorithm; the legacy -certpbe/-keypbe/-macalg values are required.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:temp -name "$CN" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -T /usr/bin/codesign puts codesign on the private key's ACL so that signing
# does not raise a keychain prompt.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign >/dev/null

echo "Created stable signing identity:"
security find-identity -p codesigning | grep "$CN"
