#!/usr/bin/env bash
# Wydanie eksportera poza sklepem: podpis Developer ID, notaryzacja, obraz.
#
# Ta sama droga co `release-mac.sh` — patrz tam, skąd każda flaga. Eksporter
# **zawsze** będzie poza sklepem: czyta bazy Photos, a do tego potrzeba
# Pełnego dostępu do dysku, którego piaskownica sklepu nie daje.
#
# Obraz zawiera skrót do Aplikacji i to nie jest ozdoba: zgoda na Pełny
# dostęp do dysku i „Open at login" są przypięte do miejsca, z którego
# program działa. Uruchomiony prosto z obrazu dostałby zgodę, która po
# odmontowaniu wskazuje w próżnię.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

KEY_ID=3MGB93VA88
ISSUER=5747fe7d-c544-4960-b0f4-380096a6c534
NAME=lightbrary-exporter
OUT=build/wydanie-exporter
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')

xcodegen generate

STAGE="$OUT/stage"
rm -rf "$OUT"; mkdir -p "$STAGE"

xcodebuild -project lightbrary.xcodeproj -scheme $NAME -configuration Release \
    -derivedDataPath build/release \
    -destination "generic/platform=macOS" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build

cp -R "build/release/Build/Products/Release/$NAME.app" "$STAGE/$NAME.app"

echo "== podpis =="
codesign --verify --deep --strict --verbose=2 "$STAGE/$NAME.app"
# Bez tego uprawnienia hardened runtime odcina dostęp do Zdjęć bez pytania.
codesign -d --entitlements - "$STAGE/$NAME.app" 2>/dev/null | grep -q photos-library \
    || { echo "brak uprawnienia photos-library w podpisie"; exit 1; }

DMG="$OUT/$NAME-$VERSION.dmg"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "lightbrary exporter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "== notaryzacja (Apple sprawdza pakiet, zwykle kilka minut) =="
xcrun notarytool submit "$DMG" --key ~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8 \
    --key-id "$KEY_ID" --issuer "$ISSUER" --wait

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "gotowe: $DMG"
