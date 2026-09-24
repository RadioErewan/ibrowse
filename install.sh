#!/usr/bin/env bash
# Budowa i instalacja lightbrary. Bez argumentu: macOS. Z "ios": na telefon.
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
else
    xcodebuild -project lightbrary.xcodeproj -scheme lightbrary-mac \
        -configuration Debug -derivedDataPath build build
    pkill -f lightbrary-mac 2>/dev/null || true

    # Dock i Finder trzymają ikonę w pamięci podręcznej i nie zauważają, że
    # pakiet się zmienił — po zmianie ikony w Docku siedziałaby stara.
    APP="build/Build/Products/Debug/lightbrary-mac.app"
    touch "$APP"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/\
LaunchServices.framework/Support/lsregister -f "$APP"

    open "$APP"
fi
