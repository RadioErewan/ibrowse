#!/usr/bin/env bash
# Składa publiczne repozytorium eksportera (github.com/RadioErewan/lightbrary-
# exporter) z plików tego repozytorium i wypycha je jednym commitem.
#
# Źródłem prawdy zostaje **to** repozytorium: eksporter dzieli z przeglądarkami
# format pliku wymiany (SyncFile, SyncFolder, CloudIdentity, Measure,
# AssetMetadata) — dwie niezależne kopie by się rozjechały. Tamto repozytorium
# jest lustrem: README, licencja i project.yml leżą w tools/exporter-repo/.
#
#   tools/publish-exporter-repo.sh            złożyć, sprawdzić kompilację, wypchnąć
#   tools/publish-exporter-repo.sh --dry-run  tylko złożyć i sprawdzić
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=../lightbrary-exporter
REMOTE=https://github.com/RadioErewan/lightbrary-exporter.git
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD_NO=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
SOURCE_COMMIT=$(git rev-parse --short HEAD)

[ -d "$TARGET/.git" ] || git clone -q "$REMOTE" "$TARGET" 2>/dev/null || { mkdir -p "$TARGET"; git -C "$TARGET" init -q -b main; git -C "$TARGET" remote add origin "$REMOTE"; }

# Czyste lustro: wszystko poza .git i prywatnym Local.xcconfig znika i wraca.
find "$TARGET" -mindepth 1 -maxdepth 1 ! -name .git ! -name Local.xcconfig -exec rm -rf {} +

mkdir -p "$TARGET/Sources" "$TARGET/Resources"
cp -R Sources/Exporter "$TARGET/Sources/"
for f in Metadata/MetadataStore.swift Metadata/AssetMetadata.swift Model/Measure.swift \
         Model/HalfFloat.swift Sync/SyncFile.swift Sync/SyncFolder.swift Sync/CloudIdentity.swift; do
    mkdir -p "$TARGET/Sources/$(dirname $f)"
    cp "Sources/$f" "$TARGET/Sources/$f"
done
cp -R Resources/Exporter.xcassets "$TARGET/Resources/"
cp Resources/lightbrary-exporter.entitlements Resources/exporter-icon-source.png "$TARGET/Resources/"
cp tools/exporter-repo/README.md tools/exporter-repo/LICENSE tools/exporter-repo/Local.xcconfig.example "$TARGET/"
cp tools/exporter-repo/gitignore "$TARGET/.gitignore"
sed "s/__VERSION__/$VERSION/; s/__BUILD__/$BUILD_NO/" tools/exporter-repo/project.yml > "$TARGET/project.yml"

# Kompilacja w lustrze — z tutejszym zespołem, jeśli brak własnego pliku.
[ -f "$TARGET/Local.xcconfig" ] || cp Local.xcconfig "$TARGET/Local.xcconfig"
(cd "$TARGET" && xcodegen generate >/dev/null && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project lightbrary-exporter.xcodeproj -scheme lightbrary-exporter \
    -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)")

[ "${1:-}" = "--dry-run" ] && { echo "złożone w $TARGET (bez wypychania)"; exit 0; }

cd "$TARGET"
git add -A
git diff --cached --quiet && { echo "bez zmian"; exit 0; }
git commit -q -m "Exporter $VERSION ($BUILD_NO) from lightbrary @ $SOURCE_COMMIT"
git push -q origin main
echo "wypchnięte: $VERSION @ $SOURCE_COMMIT"
