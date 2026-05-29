#!/bin/bash
# One-time setup: creates a persistent self-signed code-signing identity in the
# login keychain. macOS TCC keys permission grants (Accessibility, etc.) to the
# signing certificate's hash, not the binary hash. A persistent cert means
# permissions stick across rebuilds — ad-hoc signing changes the hash every
# build and would force you to re-grant every time.
#
# After this, run scripts/finalize-identity.sh to trust the cert + verify it.
# Then scripts/build-app.sh will pick it up automatically.

set -euo pipefail

IDENTITY_NAME="Mize Dev"
KEY_PATH="$(mktemp -d)/mize.key"
CERT_PATH="$(mktemp -d)/mize.crt"
P12_PATH="$(mktemp -d)/mize.p12"

# Skip if an actually-usable identity already exists (line ends in the bare name,
# no parenthetical status warning like "(Invalid Key Usage for policy)").
if security find-identity -v -p codesigning | grep -q "\"${IDENTITY_NAME}\"$"; then
    echo "✓ Identity '${IDENTITY_NAME}' already valid in keychain. Nothing to do."
    exit 0
fi

# Clean up any prior broken cert(s) with the same CN so we don't accumulate dupes.
if security find-certificate -c "${IDENTITY_NAME}" >/dev/null 2>&1; then
    echo "→ removing prior '${IDENTITY_NAME}' cert(s) from login keychain"
    while security delete-certificate -c "${IDENTITY_NAME}" 2>/dev/null; do :; done
fi

echo "→ generating 4096-bit RSA key + self-signed cert with code-signing EKU + keyUsage"
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
    -keyout "${KEY_PATH}" \
    -out "${CERT_PATH}" \
    -subj "/CN=${IDENTITY_NAME}" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE"

P12_PASS="mize-temp-$(date +%s)"
echo "→ packaging into PKCS#12 (legacy algorithms for keychain compatibility)"
openssl pkcs12 -export \
    -in "${CERT_PATH}" \
    -inkey "${KEY_PATH}" \
    -out "${P12_PATH}" \
    -name "${IDENTITY_NAME}" \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg SHA1 \
    -passout "pass:${P12_PASS}"

echo "→ importing into login keychain"
security import "${P12_PATH}" \
    -k ~/Library/Keychains/login.keychain-db \
    -P "${P12_PASS}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -A

# Allow codesign to use the private key without prompting on every build.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -k "" \
    ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true

rm -f "${KEY_PATH}" "${CERT_PATH}" "${P12_PATH}"

echo ""
echo "✓ Identity '${IDENTITY_NAME}' installed in login keychain."
echo ""
echo "Next: run scripts/trust-signing-identity.sh to mark it trusted for code signing"
echo "  (sudo prompt). Then scripts/build-app.sh will use it automatically."
