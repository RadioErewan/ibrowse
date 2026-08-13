#!/usr/bin/env bash
# Budowa i instalacja ibrowse. Bez argumentu: macOS. Z "ios": na telefon.
#
# Telefon musi być podpięty kablem i odblokowany. Podpis wygasa po 7 dniach
# (darmowe konto deweloperskie) — wtedy trzeba uruchomić to ponownie.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Identyfikator swojego telefonu znajdziesz przez:  xcrun devicectl list devices
# Ustaw go raz w powłoce:  export IBROWSE_DEVICE=...
DEVICE="${IBROWSE_DEVICE:?ustaw IBROWSE_DEVICE — patrz xcrun devicectl list devices}"

xcodegen generate

if [ "${1:-mac}" = "ios" ]; then
    xcodebuild -project ibrowse.xcodeproj -scheme ibrowse-ios \
        -configuration Debug -destination "id=$DEVICE" \
        -derivedDataPath build -allowProvisioningUpdates build
    xcrun devicectl device install app --device "$DEVICE" \
        build/Build/Products/Debug-iphoneos/ibrowse-ios.app
    echo "Wgrane. Stuknij w ikonę na telefonie."
else
    xcodebuild -project ibrowse.xcodeproj -scheme ibrowse-mac \
        -configuration Debug -derivedDataPath build build
    pkill -f ibrowse-mac 2>/dev/null || true

    # Dock i Finder trzymają ikonę w pamięci podręcznej i nie zauważają, że
    # pakiet się zmienił — po zmianie ikony w Docku siedziałaby stara.
    APP="build/Build/Products/Debug/ibrowse-mac.app"
    touch "$APP"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/\
LaunchServices.framework/Support/lsregister -f "$APP"

    open "$APP"
fi
