#!/usr/bin/env bash
# Wydanie wersji na Maca poza sklepem: podpis, notaryzacja, obraz do pobrania.
#
# Wymaga certyfikatu **Developer ID Application** w pęku kluczy. Taki podpis
# działa na każdym Macu; deweloperski działa wyłącznie na komputerach
# dopisanych do konta, więc do rozsyłania się nie nadaje.
#
# Notaryzacja to sprawdzenie pakietu przez Apple — bez niej Gatekeeper
# zatrzymuje program przy pierwszym uruchomieniu. Wymaga włączonego
# hardened runtime, dlatego jest tu włączany jawnie, choć w kompilacji
# deweloperskiej pozostaje wyłączony.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

KEY_ID=3MGB93VA88
ISSUER=5747fe7d-c544-4960-b0f4-380096a6c534
APP=lightbrary
OUT=build/wydanie
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')

xcodegen generate

rm -rf "$OUT"; mkdir -p "$OUT"

xcodebuild -project $APP.xcodeproj -scheme $APP-mac -configuration Release \
    -derivedDataPath build/release \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build

cp -R "build/release/Build/Products/Release/$APP-mac.app" "$OUT/$APP.app"

echo "== podpis =="
codesign --verify --deep --strict --verbose=2 "$OUT/$APP.app"

DMG="$OUT/$APP-$VERSION.dmg"
ln -s /Applications "$OUT/Aplikacje" 2>/dev/null || true
hdiutil create -volname "$APP" -srcfolder "$OUT" -ov -format UDZO "$DMG" >/dev/null

echo "== notaryzacja (Apple sprawdza pakiet, zwykle kilka minut) =="
xcrun notarytool submit "$DMG" --key ~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8 \
    --key-id "$KEY_ID" --issuer "$ISSUER" --wait

# Zszycie: wynik notaryzacji ląduje w samym pliku, więc działa też bez sieci.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "gotowe: $DMG"
