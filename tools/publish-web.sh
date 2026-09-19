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
set -euo pipefail

cd "$(dirname "$0")/.."

KEY=~/Documents/aws/radek3210pl.pem
HOST=ubuntu@100.70.65.114
ROOT=/var/www/lightbrary
APP=lightbrary

VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
DMG="build/wydanie/$APP-$VERSION.dmg"

[ -f "$DMG" ] || { echo "nie ma $DMG — najpierw tools/release-mac.sh"; exit 1; }

# Zszycie sprawdzamy tutaj jeszcze raz. Obraz bez niego działa na komputerze,
# który budował, i odbija się od Gatekeepera na każdym innym — czyli usterka
# ujawnia się wyłącznie u obcych ludzi.
xcrun stapler validate "$DMG" >/dev/null || { echo "$DMG nie jest zszyty"; exit 1; }

SUMA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
MB=$(echo "scale=1; $(stat -f%z "$DMG") / 1048576" | bc)

echo "wydanie $VERSION · ${MB} MB · $SUMA"

scp -i "$KEY" "$DMG" "$HOST:/tmp/" >/dev/null

ssh -i "$KEY" "$HOST" "
    set -e
    sudo mv /tmp/$APP-$VERSION.dmg $ROOT/pobierz/
    sudo chmod 644 $ROOT/pobierz/$APP-$VERSION.dmg

    # Strona pobierania: podmieniamy numer, odnośnik, rozmiar i sumę naraz.
    sudo python3 - <<PY
import io, re
p = '$ROOT/download.html'
s = io.open(p, encoding='utf-8').read()
s = re.sub(r'version [0-9][0-9.]*<', 'version $VERSION<', s)
s = re.sub(r'$APP-[0-9][0-9.]*\.dmg', '$APP-$VERSION.dmg', s)
s = re.sub(r'[0-9]+\.[0-9]+ MB', '${MB} MB', s)
s = re.sub(r'\b[0-9a-f]{64}\b', '$SUMA', s)
io.open(p, 'w', encoding='utf-8').write(s)
PY

    printf '{\n  \"version\": \"$VERSION\",\n  \"page\": \"https://lightbrary.app/download\"\n}\n' \
        | sudo tee $ROOT/wersja.json >/dev/null
    sudo chmod 644 $ROOT/wersja.json
"

echo "== sprawdzenie na żywo =="
curl -s https://lightbrary.app/wersja.json
POBRANA=$(curl -s "https://lightbrary.app/pobierz/$APP-$VERSION.dmg" | shasum -a 256 | cut -d' ' -f1)
[ "$POBRANA" = "$SUMA" ] && echo "suma pobranego zgadza się" || { echo "SUMA SIĘ NIE ZGADZA"; exit 1; }
