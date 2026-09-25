#!/usr/bin/env bash
# Mac do App Store Connect (TestFlight, potem sklep): archiwum z warunkiem
# APP_STORE i wysyłka. Potem `PLATFORM=MAC_OS tools/testflight.sh opis.txt`.
#
# Różnice wobec wersji ze strony (`release-mac.sh`):
# - `APP_STORE`: bez własnego sprawdzania aktualizacji, a miary, wyszukiwanie
#   po treści i uwagi o eksporterze pojawiają się dopiero, gdy są dane
#   (DECYZJE.md, „Piaskownica i sklep na Macu");
# - podpis dystrybucyjny sklepu (automatyczny, kluczem API) zamiast Developer ID.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

KEY_ID=3MGB93VA88
ISSUER=5747fe7d-c544-4960-b0f4-380096a6c534
TEAM=H68KFMP4TR
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
ARCHIVE="build/lightbrary-mac-store-$VERSION.xcarchive"
OPTIONS="build/ExportOptions-mac-store.plist"
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
xcodebuild -project lightbrary.xcodeproj -scheme lightbrary-mac -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    PROVISIONING_PROFILE_SPECIFIER="" DEVELOPMENT_TEAM="$TEAM" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APP_STORE' \
    "${AUTH[@]}" archive \
    | grep -E "ARCHIVE (SUCCEEDED|FAILED)|error:"

echo "== wysyłka =="
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath "build/export-mac-store-$VERSION" "${AUTH[@]}" \
    | grep -E "EXPORT (SUCCEEDED|FAILED)|error|Upload|uploaded"

echo "wysłane: Mac $VERSION — dalej PLATFORM=MAC_OS tools/testflight.sh opis.txt"
