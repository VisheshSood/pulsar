#!/bin/zsh
# Creates a self-signed "Pulsar Local Signing" code-signing certificate in your login keychain.
# Signing every build with it keeps macOS permissions (audio access, login item) across rebuilds.
# Not needed if you have a "Developer ID Application" certificate.
set -euo pipefail
if security find-identity -p codesigning | grep -q '"Pulsar Local Signing"'; then echo "Already exists."; exit 0; fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/cs.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Pulsar Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/cs.cnf" 2>/dev/null
PW=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -inkey "$D/key.pem" -in "$D/cert.pem" -name "Pulsar Local Signing" -out "$D/id.p12" -passout pass:$PW 2>/dev/null \
  || openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "Pulsar Local Signing" -out "$D/id.p12" -passout pass:$PW
security import "$D/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
echo "Created 'Pulsar Local Signing'."
