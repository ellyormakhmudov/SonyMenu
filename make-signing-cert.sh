#!/bin/bash
# Creates a private, self-signed code-signing certificate in its own keychain
# (~/.sonymenu-signing), used by build.sh so rebuilds keep their macOS permissions.
set -euo pipefail
D="$HOME/.sonymenu-signing"; KC="$D/signing.keychain-db"
mkdir -p "$D"; chmod 700 "$D"; cd "$D"
[ -f pass ] || { openssl rand -hex 24 > pass; chmod 600 pass; }
P=$(cat pass)
cat > cert.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=SonyMenu Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
[ -f key.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$P" -name "SonyMenu Local Signing"
[ -f "$KC" ] || security create-keychain -p "$P" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$P" "$KC"
security import id.p12 -k "$KC" -P "$P" -T /usr/bin/codesign >/dev/null 2>&1 || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$P" "$KC" >/dev/null
echo "Signing certificate ready in $KC"
