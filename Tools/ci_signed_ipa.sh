#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${IOS_CERTIFICATE_P12_BASE64:?Configure IOS_CERTIFICATE_P12_BASE64 secret}"
: "${IOS_CERTIFICATE_PASSWORD?Configure IOS_CERTIFICATE_PASSWORD secret}"
: "${IOS_PROFILES_ZIP_BASE64:?Configure IOS_PROFILES_ZIP_BASE64 secret}"
: "${IOS_TEAM_ID:?Configure IOS_TEAM_ID secret}"
: "${APP_BUNDLE_ID:?Missing Bundle ID}"
SIGN_DIR="$RUNNER_TEMP/zhoumu-signing"
SIGN_KEYCHAIN="$RUNNER_TEMP/zhoumu-signing.keychain-db"
mkdir -p "$SIGN_DIR" build
chmod 700 "$SIGN_DIR"
export SIGN_DIR
python3 - <<'PY'
import base64, os
from pathlib import Path
for name, variable in [('certificate.p12', 'IOS_CERTIFICATE_P12_BASE64'), ('profiles.zip', 'IOS_PROFILES_ZIP_BASE64')]:
    Path(os.environ['SIGN_DIR'], name).write_bytes(base64.b64decode(os.environ[variable], validate=True))
PY
SIGN_PASSWORD="$(openssl rand -hex 24)"
security create-keychain -p "$SIGN_PASSWORD" "$SIGN_KEYCHAIN"
security set-keychain-settings -lut 21600 "$SIGN_KEYCHAIN"
security unlock-keychain -p "$SIGN_PASSWORD" "$SIGN_KEYCHAIN"
security import "$SIGN_DIR/certificate.p12" -P "$IOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$SIGN_KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$SIGN_PASSWORD" "$SIGN_KEYCHAIN" >/dev/null
security list-keychains -d user -s "$SIGN_KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
SIGN_IDENTITY="$(security find-identity -v -p codesigning "$SIGN_KEYCHAIN" | sed -n 's/.*) \([A-F0-9]\{40\}\) .*/\1/p' | head -n 1)"
[ -n "$SIGN_IDENTITY" ] || { echo 'No valid code signing identity in certificate'; exit 1; }
python3 Tools/ci_profiles.py
set -o pipefail
xcodebuild -project ZhouMu.xcodeproj -scheme ZhouMu -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/ZhouMu.xcarchive \
  APP_BUNDLE_ID="$APP_BUNDLE_ID" DEVELOPMENT_TEAM="$IOS_TEAM_ID" \
  CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--keychain $SIGN_KEYCHAIN" archive | tee build/archive.log
xcodebuild -exportArchive -archivePath build/ZhouMu.xcarchive \
  -exportOptionsPlist build/CIExportOptions.plist -exportPath build/signed | tee build/export.log
