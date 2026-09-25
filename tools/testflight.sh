#!/usr/bin/env bash
# Build z App Store Connect do grupy zewnętrznych testerów (TestFlight):
# czeka na przetworzenie, ustawia „What to Test", dodaje do grupy External
# i zgłasza do recenzji bety. Opis zmian po angielsku, z pliku.
#
#   tools/testflight.sh opis.txt                  iPhone
#   PLATFORM=MAC_OS tools/testflight.sh opis.txt  Mac (po release-mac-store.sh)
set -euo pipefail
PLATFORM="${PLATFORM:-IOS}"
cd "$(dirname "$0")/.."

WHATS="${1:?plik z opisem zmian (What to Test)}"
APP=6812906504
GROUP=fc2c2a53-214f-4ee7-9b05-4c282a9b49af   # External
API=https://api.appstoreconnect.apple.com/v1
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD_NO=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')

token() { bash tools/asc-token.sh 3MGB93VA88 5747fe7d-c544-4960-b0f4-380096a6c534; }
get() { curl -s -H "Authorization: Bearer $(token)" "$API/$1"; }
send() { curl -s -X "$1" -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" -d "$3" "$API/$2"; }

echo "== czekam na build $PLATFORM $VERSION ($BUILD_NO) =="
for _ in $(seq 1 60); do
    read -r B STATE < <(get "builds?filter%5Bapp%5D=$APP&filter%5Bversion%5D=$BUILD_NO&filter%5BpreReleaseVersion.version%5D=$VERSION&filter%5BpreReleaseVersion.platform%5D=$PLATFORM" \
        | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d[0]['id'], d[0]['attributes']['processingState']) if d else print('- -')")
    echo "  $STATE"
    [ "$STATE" = "VALID" ] && break
    [ "$STATE" = "INVALID" ] && { echo "Apple odrzucił build"; exit 1; }
    sleep 30
done
[ "$STATE" = "VALID" ] || { echo "build nieprzetworzony po 30 min"; exit 1; }

LOC=$(get "builds/$B/betaBuildLocalizations" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(next((l['id'] for l in d if l['attributes']['locale']=='en-US'), ''))")
TEXT=$(cat "$WHATS")
if [ -n "$LOC" ]; then
    BODY=$(python3 -c "import json,sys; print(json.dumps({'data':{'type':'betaBuildLocalizations','id':sys.argv[1],'attributes':{'whatsNew':sys.argv[2]}}}))" "$LOC" "$TEXT")
    send PATCH "betaBuildLocalizations/$LOC" "$BODY" >/dev/null
else
    BODY=$(python3 -c "import json,sys; print(json.dumps({'data':{'type':'betaBuildLocalizations','attributes':{'locale':'en-US','whatsNew':sys.argv[2]},'relationships':{'build':{'data':{'type':'builds','id':sys.argv[1]}}}}}))" "$B" "$TEXT")
    send POST "betaBuildLocalizations" "$BODY" >/dev/null
fi
echo "== opis ustawiony =="

send POST "betaGroups/$GROUP/relationships/builds" "{\"data\":[{\"type\":\"builds\",\"id\":\"$B\"}]}" >/dev/null
echo "== w grupie External =="

send POST "betaAppReviewSubmissions" \
    "{\"data\":{\"type\":\"betaAppReviewSubmissions\",\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$B\"}}}}}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('zgłoszone do recenzji:', (d.get('data') or {}).get('attributes') or d.get('errors'))"
