#!/usr/bin/env bash
# Wystawienie gotowego wydania na lightbrary.app.
#
# **Osobno od budowania, i to celowo.** `release-mac.sh` kończy się plikiem
# DMG, którego nikt jeszcze nie uruchomił. Zdarzyło się już wydanie zbudowane
# i znotaryzowane z usterką, którą wyłapało dopiero użycie — gdyby publikacja
# wisiała na końcu budowania, wyszłaby na stronę sama z siebie. Więc najpierw
# się sprawdza, potem woła ten skrypt.
#
# Robi trzy rzeczy, bo wszystkie trzy muszą się zgadzać albo żadna:
#   1. wgrywa obraz,
#   2. przestawia stronę pobierania (numer, nazwa pliku, rozmiar, suma),
#   3. odświeża `wersja.json`, z którego aplikacja czyta „Sprawdź aktualizacje".
#
# **Czego ten skrypt NIE rusza**: napisu „macOS XX or later" na stronie
# głównej i stronie pobierania. To zwykły tekst w HTML-u, nie zmienna —
# przy zmianie `deploymentTarget` w project.yml trzeba go poprawić ręcznie
# (`grep -rn "macOS.*or later" na serwerze). Przeoczone raz przy skoku
# z macOS 14 na 27 — strona kłamała przez jedno wydanie.
#
# Pominięcie punktu trzeciego jest najgroźniejsze i najcichsze: wydanie leży
# na stronie, a program w komputerach ludzi dalej twierdzi, że jest aktualny.
#
#   tools/publish-web.sh            lightbrary (build/wydanie, po release-mac.sh)
#   tools/publish-web.sh exporter   eksporter (build/wydanie-exporter, po
#                                   release-exporter.sh); bez `wersja.json`,
#                                   bo eksporter nie sprawdza aktualizacji
#
# Na stronie leżą dwa pliki, więc podmiany działają **tylko wewnątrz bloków**
# `<!--mac-->…<!--/mac-->` albo `<!--exporter-->…<!--/exporter-->`. Wcześniej
# szły po całej stronie: każdy rozmiar w MB i każda suma SHA-256 dostawałyby
# wartości ostatnio wydanego pliku, także te należące do drugiego.
set -euo pipefail

cd "$(dirname "$0")/.."

KEY=~/Documents/aws/radek3210pl.pem
HOST=ubuntu@100.70.65.114
ROOT=/var/www/lightbrary

VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ "${1:-mac}" = "exporter" ]; then
    APP=lightbrary-exporter; BLOCK=exporter; OUT=build/wydanie-exporter; SCRIPT=release-exporter.sh
else
    APP=lightbrary; BLOCK=mac; OUT=build/wydanie; SCRIPT=release-mac.sh
fi
DMG="$OUT/$APP-$VERSION.dmg"

[ -f "$DMG" ] || { echo "nie ma $DMG — najpierw tools/$SCRIPT"; exit 1; }

# Zszycie sprawdzamy tutaj jeszcze raz. Obraz bez niego działa na komputerze,
# który budował, i odbija się od Gatekeepera na każdym innym — czyli usterka
# ujawnia się wyłącznie u obcych ludzi.
xcrun stapler validate "$DMG" >/dev/null || { echo "$DMG nie jest zszyty"; exit 1; }

SUMA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
# `printf`, nie `bc`: bc pisze pół megabajta jako ".5", a tego wzorzec
# „liczba MB" przy następnym wydaniu już nie złapie.
MB=$(awk "BEGIN { printf \"%.1f\", $(stat -f%z "$DMG") / 1048576 }")

echo "wydanie $VERSION · ${MB} MB · $SUMA"

scp -i "$KEY" "$DMG" "$HOST:/tmp/" >/dev/null

ssh -i "$KEY" "$HOST" "
    set -e
    sudo mv /tmp/$APP-$VERSION.dmg $ROOT/pobierz/
    sudo chmod 644 $ROOT/pobierz/$APP-$VERSION.dmg

    # Strona pobierania: numer, odnośnik, rozmiar i suma naraz, tylko w blokach
    # tego pliku. Bez ani jednego bloku to błąd, nie cicha pustka.
    sudo cp $ROOT/download.html $ROOT/download.html.bak
    sudo python3 - <<PY
import io, re, sys
p = '$ROOT/download.html'
s = io.open(p, encoding='utf-8').read()
def fix(m):
    b = m.group(0)
    b = re.sub(r'version [0-9][0-9.]*<!--/', 'version $VERSION<!--/', b)
    b = re.sub(r'$APP-[0-9][0-9.]*\.dmg', '$APP-$VERSION.dmg', b)
    b = re.sub(r'[0-9]+\.[0-9]+ MB', '${MB} MB', b)
    b = re.sub(r'\b[0-9a-f]{64}\b', '$SUMA', b)
    return b
s, n = re.subn(r'<!--$BLOCK-->.*?<!--/$BLOCK-->', fix, s, flags=re.S)
if n == 0:
    sys.exit('download.html nie ma bloku <!--$BLOCK-->')
io.open(p, 'w', encoding='utf-8').write(s)
PY

    [ $BLOCK = mac ] || exit 0
    printf '{\n  \"version\": \"$VERSION\",\n  \"page\": \"https://lightbrary.app/download\"\n}\n' \
        | sudo tee $ROOT/wersja.json >/dev/null
    sudo chmod 644 $ROOT/wersja.json
"

echo "== sprawdzenie na żywo =="
[ $BLOCK = mac ] && curl -s https://lightbrary.app/wersja.json
curl -s https://lightbrary.app/download | grep -q "$SUMA" && echo "strona pokazuje nową sumę" \
    || { echo "STRONA NIE POKAZUJE NOWEJ SUMY"; exit 1; }
POBRANA=$(curl -s "https://lightbrary.app/pobierz/$APP-$VERSION.dmg" | shasum -a 256 | cut -d' ' -f1)
[ "$POBRANA" = "$SUMA" ] && echo "suma pobranego zgadza się" || { echo "SUMA SIĘ NIE ZGADZA"; exit 1; }
