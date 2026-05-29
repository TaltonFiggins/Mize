#!/bin/bash
# Final setup for the "Mize Dev" code-signing identity:
#   1. Sets keychain partition list so codesign can use the private key
#      without prompting on every build (needs your login keychain password).
#   2. Trusts the cert in the System keychain for code-signing use (needs sudo).
#   3. Verifies the identity and runs a no-op codesign as a smoke test.
#
# Run once after scripts/create-signing-identity.sh.

set -euo pipefail

IDENTITY_NAME="Mize Dev"

if ! security find-certificate -c "${IDENTITY_NAME}" >/dev/null 2>&1; then
    echo "✗ No '${IDENTITY_NAME}' cert in login keychain."
    echo "  Run scripts/create-signing-identity.sh first."
    exit 1
fi

echo "Login keychain password (same as your macOS login password):"
read -rs KEYCHAIN_PASS
echo ""

echo "→ setting keychain partition list (so codesign won't prompt on every build)"
security set-key-partition-list \
    -S "apple-tool:,apple:,codesign:" \
    -k "${KEYCHAIN_PASS}" \
    ~/Library/Keychains/login.keychain-db >/dev/null

# Drop the password from environment ASAP.
unset KEYCHAIN_PASS

echo "→ trusting cert for code signing in System keychain (sudo prompt next)"
CERT_PATH="$(mktemp -t mize-dev-cert).crt"
security find-certificate -c "${IDENTITY_NAME}" -p > "${CERT_PATH}"
sudo security add-trusted-cert -d \
    -r trustRoot \
    -p codeSign \
    -k /Library/Keychains/System.keychain \
    "${CERT_PATH}"
rm -f "${CERT_PATH}"

echo ""
echo "→ verifying identity"
if ! security find-identity -v -p codesigning | grep -q "\"${IDENTITY_NAME}\"$"; then
    echo "✗ '${IDENTITY_NAME}' still not valid for code signing:"
    security find-identity -p codesigning | grep "${IDENTITY_NAME}" || true
    exit 1
fi
security find-identity -v -p codesigning | grep "${IDENTITY_NAME}"

echo ""
echo "→ smoke test: codesigning a temp file"
TMP_BIN="$(mktemp -t mize-smoke)"
cp /bin/echo "${TMP_BIN}"
if codesign --force --sign "${IDENTITY_NAME}" "${TMP_BIN}" 2>&1; then
    echo "✓ codesign succeeded — identity is ready"
else
    echo "✗ codesign failed on smoke test"
    rm -f "${TMP_BIN}"
    exit 1
fi
rm -f "${TMP_BIN}"

echo ""
echo "Done. scripts/build-app.sh will now sign with '${IDENTITY_NAME}'."
