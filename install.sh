#!/usr/bin/env bash
# Budowa i instalacja lightbrary. Bez argumentu: macOS. Z "release": macOS
# z optymalizacją. Z "ios": na telefon.
# Z "exporter": eksporter w pasku menu.
#
# Telefon musi być podpięty kablem i odblokowany. Podpis wygasa po 7 dniach
# (darmowe konto deweloperskie) — wtedy trzeba uruchomić to ponownie.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodegen generate

if [ "${1:-mac}" = "ios" ]; then
    # Identyfikator swojego telefonu znajdziesz przez:  xcrun devicectl list devices
    # Ustaw go raz w powłoce:  export LIGHTBRARY_DEVICE=...
    DEVICE="${LIGHTBRARY_DEVICE:?ustaw LIGHTBRARY_DEVICE — patrz xcrun devicectl list devices}"
    xcodebuild -project lightbrary.xcodeproj -scheme lightbrary-ios \
        -configuration Debug -destination "id=$DEVICE" \
        -derivedDataPath build -allowProvisioningUpdates build
    xcrun devicectl device install app --device "$DEVICE" \
        build/Build/Products/Debug-iphoneos/lightbrary-ios.app
    echo "Wgrane. Stuknij w ikonę na telefonie."
elif [ "${1:-mac}" = "exporter" ]; then
    # Zawsze ta sama ścieżka: zgoda na Pełny dostęp do dysku jest przypięta
    # do konkretnego pakietu, więc eksporter nie może wędrować po dysku.
    xcodebuild -project lightbrary.xcodeproj -scheme lightbrary-exporter \
        -configuration Debug -derivedDataPath build build
    pkill -f lightbrary-exporter 2>/dev/null || true
    open "build/Build/Products/Debug/lightbrary-exporter.app"
    echo "Eksporter działa w pasku menu (znak pasowania)."
else
    # `./install.sh release` — ta sama aplikacja, ale skompilowana
    # z optymalizacją. Debug bywa w siatce kilka–kilkanaście razy wolniejszy,
    # więc płynność ocenia się tylko na tym. Podpis zostaje deweloperski,
    # czyli zakładki do folderów i zgoda na Zdjęcia się nie gubią.
    CONFIG=Debug
    [ "${1:-mac}" = "release" ] && CONFIG=Release
    xcodebuild -project lightbrary.xcodeproj -scheme lightbrary-mac \
        -configuration "$CONFIG" -derivedDataPath build build \
        CODE_SIGN_IDENTITY="Apple Development"
    pkill -f lightbrary-mac 2>/dev/null || true

    # Dock i Finder trzymają ikonę w pamięci podręcznej i nie zauważają, że
    # pakiet się zmienił — po zmianie ikony w Docku siedziałaby stara.
    APP="build/Build/Products/$CONFIG/lightbrary-mac.app"
    touch "$APP"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/\
LaunchServices.framework/Support/lsregister -f "$APP"

    open "$APP"
fi
