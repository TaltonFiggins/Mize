#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Mize"
BUNDLE_ID="${MIZE_BUNDLE_ID:-dev.mizeapp.Mize}"  # override via MIZE_BUNDLE_ID env var
CONFIG="${CONFIG:-debug}"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH=".build/${CONFIG}/${APP_NAME}"
if [ ! -f "${BIN_PATH}" ]; then
    echo "✗ Binary not found at ${BIN_PATH}"
    exit 1
fi

echo "→ assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"

cat > "${CONTENTS}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Mize</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Sign with persistent identity if a clean one exists, otherwise ad-hoc.
# Persistent identity makes TCC permission grants stick across rebuilds.
# Look up by hash to disambiguate from any stale duplicate-CN certs.
IDENTITY_NAME="Mize Dev"
IDENTITY_HASH="$(security find-identity -v -p codesigning | grep "\"${IDENTITY_NAME}\"\$" | head -1 | awk '{print $2}')"
if [ -n "${IDENTITY_HASH}" ]; then
    echo "→ signing with '${IDENTITY_NAME}' (${IDENTITY_HASH:0:10}…)"
    codesign --force --deep --sign "${IDENTITY_HASH}" --options runtime "${APP_DIR}"
else
    echo "→ signing ad-hoc (no valid '${IDENTITY_NAME}' identity found)"
    echo "  Run scripts/create-signing-identity.sh then scripts/finalize-identity.sh"
    codesign --force --deep --sign - "${APP_DIR}"
fi

# Register with Launch Services so the OS recognizes it as an installed app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${APP_DIR}" >/dev/null 2>&1 || true

echo ""
echo "✓ Built ${APP_DIR}"
echo ""
echo "Run with:  open ${APP_DIR}"
echo ""
echo "Note: launch via 'open' or Spotlight, not by invoking the binary directly"
echo "from a terminal — macOS attributes Accessibility permission to the launching"
echo "terminal app (Ghostty / iTerm / Terminal.app) rather than to Mize."
