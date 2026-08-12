# Dziennik decyzji

Co ustaliliśmy i dlaczego — żeby przy powrocie do projektu nie odtwarzać
rozumowania od zera. Zapisane są **powody**, bo kod pokazuje tylko wynik.

## Czym to jest

Narzędzie do **wielokrotnego przeglądania** archiwum zdjęć: ocenianie,
porównywanie i usuwanie. Nie katalog i nie tagger — sortownik.

Punkt wyjścia: 25 882 zdjęcia w Apple Photos (117 GB), z czego 24 984 to
fotografie. Archiwum jest już raz przebrane (100 tys. → 25 tys.), a poza
biblioteką leży jeszcze 0,5–1 TB starych sesji.

Praca rozłożona na lata i wiele podejść, nie na jedno posiedzenie — to jest
najważniejsze założenie i z niego wynika większość decyzji.

## Model danych

**Jedna waga ciągła 0–5**, a gwiazdki to tylko jej zaokrąglony widok.
Trzy sposoby oceniania piszą do tej samej liczby: klawisze 1–5 ustawiają
wprost, `−`/`+` i swipe przesuwają o 0,25, wygrana w parowaniu podbija.

Powód: przy „za dużo dobrych zdjęć lasu" wszystko jest czwórką i skala
bezwzględna przestaje różnicować. Przesuwanie względne działa dalej, jest
tańsze poznawczo i odporne na dryf gustu — oceniasz względem dzisiejszego
siebie, nie sprzed sześciu lat.

`judgements` liczy, ile razy zdjęcie przeszło przez ocenianie — odróżnia
przemyślane od ledwo dotkniętego.

## Dostęp do biblioteki

**PhotoKit, nie `Photos.sqlite`.** Baza jest szybsza i pokazuje więcej, ale
istnieje tylko na macOS, wymaga pełnego dostępu do dysku i zmienia schemat
z każdym wydaniem systemu. PhotoKit działa identycznie na obu platformach
i sam dociąga oryginały z iCloud.

Czego PhotoKit **nie** daje (sprawdzone, nie założone): `keywords`, `title`,
`caption`, żadnego API do usuwania lokalnych kopii, żadnej informacji o tym,
co jest lokalnie.

## Wykrywanie serii

`VNGenerateImageFeaturePrintRequest` — 768 wymiarów, liczone na urządzeniu,
bez pobierania modelu. Około 12 ms na zdjęcie.

Trzy reguły, każda dopisana po tym, jak poprzednia zawiodła na prawdziwych
danych:

1. **Okno czasowe ±5 min** — las z 2014 podobny do lasu z 2023 to nie seria.
2. **Kadencja nadrzędna** (≤3 s) — przy starcie samolotu kolejne klatki są
   wizualnie odległe, choć to jedno naciśnięcie spustu. Ale kadencja
   **rozluźnia próg (×2,2), a nie znosi go** — inaczej w 18 sekund do jednej
   serii wpadały pierogi i garaż.
3. **Kotwica czasowa 10 min** — łączenie łańcuchowe dryfuje: A pasuje do B,
   B do C, i po trzydziestu krokach seria nie ma nic wspólnego z początkiem.

Wektory pakowane do half-float (1536 B zamiast 3072). Zmierzone: **zero par
zmienia przynależność do grupy**, skład schodzi z 78 do 39 MB.

Konwersja jest napisana ręcznie, bo typ `Float16` nie istnieje na macOS
x86_64 — inaczej format zapisu zależałby od architektury.

## Parowanie

Turniej króla wzgórza: zwycięzca zostaje i mierzy się z następnym. Seria z N
zdjęć kosztuje N−1 decyzji zamiast N²/2.

Widok zawsze podaje **pierwszą nierozstrzygniętą serię** — nie ma indeksu do
zapamiętywania, wracasz po tygodniu i trafiasz tam, gdzie skończyłeś.

**Odrzucenie serii jest osobne od pominięcia.** Pominięcie znaczy „nie teraz",
odrzucenie — „algorytm się pomylił". Odsetek odrzuceń mówi wprost, czy próg
czułości jest źle ustawiony.

## Synchronizacja

**Albumy Photos `ibrowse ★1`…`★5`**, nie CloudKit — ten wymaga płatnego konta
dewelopera. Nie słowa kluczowe, bo PhotoKit ich nie zna.

Przez albumy jeździ **gwiazdka, nie pełna waga**; dwadzieścia albumów po 0,25
zaśmieciłoby bibliotekę. Wczytywanie **nie nadpisuje** istniejących ocen —
nie znamy czasu oceny na drugim urządzeniu, więc rozstrzyganie konfliktów
byłoby zgadywaniem.

## Miejsce na dysku

PhotoKit **nie ma API do usuwania lokalnych oryginałów**. Sterować można
wyłącznie popytem, więc prefetch na iOS ma **wyłączoną sieć** — inaczej
przeglądanie archiwum kopiowałoby iCloud na telefon.

Rozważane i odrzucone: wymuszanie presji na dysk, żeby system sam posprzątał.
Działa, ale nie da się wycelować, na iOS czyści najpierw własną aplikację,
grozi utratą cudzych danych i opiera się na nieudokumentowanym zachowaniu.

## Interfejs

**Wspólny jest model, nie układ.** Cztery razy przenieśliśmy poziomy pasek
z Maca na telefon i za każdym razem rozsypywał się na jedną literę w wierszu.
Każdy widok ma teraz własny chrome pod `#if os(…)`.

Ładowanie obrazu jest **dwustopniowe**: najlepszy wariant z dysku natychmiast,
potem podmiana na pełny z iCloud. Jedno żądanie dawało albo miniaturę 64×37,
albo czarny ekran na czas pobierania.

Siatka służy do nawigacji (dwuklik wchodzi w ocenianie od wskazanego zdjęcia)
i przeglądu własnej pracy. **Nie** do oceniania — kusi do przewijania zamiast
do decydowania.

## Co czeka

- **Panel metadanych na macOS.** Most zweryfikowany: `PHAsset.localIdentifier`
  → UUID → `struct.unpack("<qq")` → `assets.rowid` → `ga` → `groups`
  w `psi.sqlite`. Trafność 38/40. Otwiera 835 920 etykiet, pełny OCR,
  geolokację i własne słowa kluczowe.
- **Krok malejący albo Elo** — przy serii 20+ lider wygrywa kilkanaście razy
  i wychodzi na sufit skali.
- **Synchronizacja odcisków i stanu serii** — dziś każde urządzenie liczy
  osobno i nie widzi rozstrzygnięć drugiego.
- **Pasek narzędzi na macOS** — „policz odciski" ucina się do „p…".
- **Archiwum 0,5–1 TB poza Photos** — katalog musi traktować bibliotekę jako
  jedno ze źródeł, nie jako fundament.

## Ograniczenia darmowego konta

Podpis wygasa po **7 dniach** — potem `./install.sh ios`. Bez CloudKit, bez
powiadomień. Team ID w `Local.xcconfig`, poza repozytorium.
