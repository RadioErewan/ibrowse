#!/usr/bin/env bash
# Wydanie wersji na Maca poza sklepem: podpis, notaryzacja, obraz do pobrania.
#
# Wymaga certyfikatu **Developer ID Application** w pęku kluczy. Taki podpis
# działa na każdym Macu; deweloperski działa wyłącznie na komputerach
# dopisanych do konta, więc do rozsyłania się nie nadaje.
#
# `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` jest konieczne: bez tego Xcode
# dokłada do podpisu uprawnienie `get-task-allow`, czyli zgodę na podpięcie
# debuggera. Apple odrzuca z nim notaryzację, i słusznie — program do
# rozdawania nie ma prawa dać się podglądać w środku.
#
# Notaryzacja to sprawdzenie pakietu przez Apple — bez niej Gatekeeper
# zatrzymuje program przy pierwszym uruchomieniu. Wymaga włączonego
# hardened runtime, dlatego jest tu włączany jawnie, choć w kompilacji
# deweloperskiej pozostaje wyłączony.
#
# `-destination "generic/platform=macOS"` jest konieczne, mimo że projekt ma
# już ARCHS="arm64 x86_64" w konfiguracji Release. Bez jawnego celu xcodebuild
# przywiązuje się do jednej, konkretnej maszyny — tej, na której kompiluje —
# i cicho ignoruje ARCHS, bez ostrzeżenia w logu. Wychodzi wtedy binarka tylko
# pod Apple Silicon, a na Intelu program nawet się nie otworzy.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

KEY_ID=3MGB93VA88
ISSUER=5747fe7d-c544-4960-b0f4-380096a6c534
APP=lightbrary
OUT=build/wydanie
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')

xcodegen generate

STAGE="$OUT/stage"
rm -rf "$OUT"; mkdir -p "$STAGE"

xcodebuild -project $APP.xcodeproj -scheme $APP-mac -configuration Release \
    -derivedDataPath build/release \
    -destination "generic/platform=macOS" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build

cp -R "build/release/Build/Products/Release/$APP-mac.app" "$STAGE/$APP.app"

echo "== podpis =="
codesign --verify --deep --strict --verbose=2 "$STAGE/$APP.app"

# Obraz powstaje **obok** katalogu, który pakuje. Zapisywany do środka
# próbowałby zawrzeć sam siebie.
DMG="$OUT/$APP-$VERSION.dmg"
ln -s /Applications "$STAGE/Aplikacje"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "== notaryzacja (Apple sprawdza pakiet, zwykle kilka minut) =="
xcrun notarytool submit "$DMG" --key ~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8 \
    --key-id "$KEY_ID" --issuer "$ISSUER" --wait

# Zszycie: wynik notaryzacji ląduje w samym pliku, więc działa też bez sieci.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "gotowe: $DMG"
