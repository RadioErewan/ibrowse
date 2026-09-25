#!/usr/bin/env bash
# Wydanie na iOS: archiwum i wysyłka do App Store Connect. Potem
# `tools/testflight.sh` — Apple przetwarza build kilka–kilkanaście minut,
# zanim da się go dodać do grupy testerów.
#
# Podpis automatyczny z kluczem API (`-allowProvisioningUpdates` + klucz):
# xcodebuild sam dociąga profil dystrybucyjny, bez logowania do Xcode.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

KEY_ID=3MGB93VA88
ISSUER=5747fe7d-c544-4960-b0f4-380096a6c534
TEAM=H68KFMP4TR
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
ARCHIVE="build/lightbrary-ios-$VERSION.xcarchive"
OPTIONS="build/ExportOptions-ios.plist"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"
      -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

xcodegen generate

cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

rm -rf "$ARCHIVE"
xcodebuild -project lightbrary.xcodeproj -scheme lightbrary-ios -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" "${AUTH[@]}" archive \
    | grep -E "ARCHIVE (SUCCEEDED|FAILED)|error:"

echo "== wysyłka =="
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath "build/export-ios-$VERSION" "${AUTH[@]}" \
    | grep -E "EXPORT (SUCCEEDED|FAILED)|error|Upload|uploaded"

echo "wysłane: $VERSION — dalej tools/testflight.sh plik-z-opisem-zmian"
