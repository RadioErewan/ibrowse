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

**Jeden wskaźnik miejsca na całą aplikację.** Każdy tryb zapisuje, na czym
stanął, i każdy czyta cudzy zapis: siatka przewija się tam, gdzie skończyło
się ocenianie, ocenianie zaczyna tam, gdzie padł dwuklik, a z pojedynku
wychodzi dotychczasowy lider. Wcześniej powrót do siatki lądował na początku
archiwum. Kafelek dostaje żółtą ramkę, bo samo wyśrodkowanie nic nie mówi,
gdy wokół są setki podobnych miniatur.

**Pominięcie musi kosztować tyle co ocena.** Na telefonie poziomą oś zabrała
waga i nie było jak przejść dalej — pierwsze wątpliwe zdjęcie albo zatrzymywało
pracę, albo dostawało ocenę wymuszoną brakiem wyjścia. Takie oceny zatruwają
skalę tam, gdzie jest najwrażliwsza. Pion przechodzi dalej i wstecz, a oś
rozstrzyga **przewaga** jednego kierunku nad drugim, nie sam próg: palec nigdy
nie idzie prosto i ukośny ruch potrafiłby ocenić i przeskoczyć naraz.

**Nic nie chowa się wewnątrz `Menu` na iOS.** Dotknięcie zamyka menu, a razem
z nim znika kotwica, do której przypięty jest popover czy arkusz — okienko
mrugało i nie pokazywało się wcale. Ten sam błąd trafił nas dwa razy, raz
z `Pickerem`, raz piętro wyżej z filtrem lat. Filtr ma teraz własny przycisk
na pasku i arkusz przypięty do ekranu, a lata idą pełną listą, bo dwadzieścia
pozycji w rozwijanym menu ucinało się w połowie.

## Filtrowanie

**Jeden zestaw warunków na całą aplikację**, jak wskaźnik miejsca. Wcześniej
rok siedział w `PhotoLibrary`, a stan oceny w `CullView` — siatka i ocenianie
pokazywały co innego i przejście między nimi gubiło kontekst.

Warunki idą w dwóch etapach i to jest decyzja o wydajności, nie o porządku.
**Rok i szukanie** zmieniają się rzadko, więc ich wynik trzymamy policzony.
**Ocena** zmienia się przy każdym naciśnięciu klawisza, więc jest predykatem
nakładanym w widoku — przeliczanie 25 tysięcy pozycji po każdej ocenie byłoby
marnotrawstwem, a zajrzenie do słownika kosztuje tyle co nic.

Szukanie idzie po `normalized_string` w `psi.sqlite`, gdzie Apple trzyma wersję
bez znaków diakrytycznych i wielkich liter. Zwykłe `LIKE` zamiast leżącego obok
indeksu pełnotekstowego: 56 tysięcy wierszy przelatuje w ćwierć sekundy,
a `LIKE '%x%'` znajduje też środek słowa, czego indeks przedrostkowy nie umie.
Zwłoka 300 ms, żeby nie odpytywać bazy przy każdej literze.

`nil` w zbiorze trafień znaczy „nie szukamy", pusty zbiór — „szukaliśmy i nic
nie ma". Bez tego rozróżnienia puste pole wyszukiwania kasowałoby cały widok.

**Szukanie po treści działa tylko na Macu.** Indeks leży w pakiecie biblioteki
na dysku; telefon go nie ma, a przepisywanie 285 tysięcy przypisań przez albumy
byłoby lekarstwem gorszym od choroby.

Etykieta przycisku wypisuje nałożone warunki (`★4–5 · 2019–2021`), bo filtr
założony wczoraj i zapomniany wygląda jak zniknięte archiwum.

Licznik liczy na żywo, w otwartym panelu. Bez tego zawężanie zakresu to
strzelanie w ciemno i zamykanie okna po każdej zmianie, żeby sprawdzić wynik.

**Parowanie filtra nie respektuje** — serie liczone są dla całego archiwum
i przycięcie ich zakresem rozrywałoby je w połowie.

## Metadane

Panel boczny w ocenianiu, **tylko macOS** — na telefonie nie ma miejsca i nie
ma po co. Pokazuje to, czego PhotoKit nie oddaje: nazwy miejsc, rozpoznane
osoby i zwierzęta, etykiety scen, odczytany tekst oraz technikę zdjęcia.

Źródła są dwa i to jest **świadome odstępstwo** od zasady „PhotoKit, nie
SQLite". Zasada broni fundamentu — oceny, serie i usuwanie idą wyłącznie przez
oficjalne API. Panel jest dodatkiem: gdy Apple przestawi kolumny, panel zgaśnie
i nic poza nim się nie stanie.

- `database/search/psi.sqlite` — etykiety, ludzie, miejsca, słowa z OCR.
  Klucz to UUID zapisany jako **dwie liczby**: bajty 0–7 i 8–15 czytane
  little-endian. Napisy kończy bajt zerowy, trzeba go obciąć.
- `database/Photos.sqlite` → `ZEXTENDEDATTRIBUTES` — ISO, przysłona, czas,
  ogniskowa, obiektyw. Tu UUID jest zwykłym napisem i jest zaindeksowany.

**Baz nie kopiujemy.** `Photos.sqlite` ma gigabajt, a wolnego miejsca na dysku
jest mniej niż samego archiwum. Otwieramy w miejscu przez `mode=ro`, a gdy to
zawiedzie (brak pliku `-shm`, bo Zdjęcia nie działają) — przez `immutable=1`.

Panel wymaga **Pełnego dostępu do dysku**: zgoda na bibliotekę zdjęć dotyczy
PhotoKit, nie plików. Dlatego aplikacja na Macu jest podpisana prawdziwym
certyfikatem zamiast doraźnie — TCC zapamiętuje tożsamość podpisu, a podpis
doraźny zmienia się przy każdej kompilacji i uprawnienie trzeba by nadawać
po każdej przebudowie.

## Ikona

Jeden rysunek, **dwa kadry** — bo platformy chcą czegoś przeciwnego. Na Macu
ikona sama nosi zaokrąglony kształt i margines wokół niego, bo system niczego
nie przycina. Na iOS kanwa musi być wypełniona do krawędzi, bo maskę nakłada
system; ten sam plik dałby tam zaokrąglony kwadracik w białej ramce.

`tools/make-icon.swift` robi komplet z `Resources/icon-source.png`. Uwaga na
kierunek parametru: **większy udział to szerszy kadr, czyli mniejszy kafelek**.
Dla tego rysunku wyszło 0,835.

Na Macu pełen komplet od 16 px, nie samo 1024 — małe kafelki widuje się
częściej niż duże, a skalowane w locie rozmywają się w plamę. Alfę spłaszczamy
na biało, bo iOS odrzuca ikony z przezroczystością.

Dock i Finder trzymają ikonę w pamięci podręcznej i nie zauważają zmiany
w pakiecie, więc `install.sh` przerejestrowuje aplikację w LaunchServices.

## Co czeka

- **Krok malejący albo Elo** — przy serii 20+ lider wygrywa kilkanaście razy
  i wychodzi na sufit skali. Najbliższa realna wada, widoczna od razu przy
  większych seriach.
- **Wyszukiwarka po OCR i etykietach.** Indeks jest już otwarty i czytany,
  brakuje tylko zapytania w drugą stronę: od słowa do zdjęć. Uwaga na skalę
  — tekst jest zaindeksowany tylko dla 1 756 zdjęć, nie dla całego archiwum.
- **Metadane w pojedynku** — przy dwóch podobnych klatkach ISO i czas
  rozstrzygają szybciej niż oko.
- **Synchronizacja odcisków i stanu serii** — dziś każde urządzenie liczy
  osobno i nie widzi rozstrzygnięć drugiego.
- **Pasek narzędzi na macOS** — „policz odciski" ucina się do „p…".
- **Archiwum 0,5–1 TB poza Photos** — katalog musi traktować bibliotekę jako
  jedno ze źródeł, nie jako fundament.

## Ograniczenia darmowego konta

Podpis wygasa po **7 dniach** — potem `./install.sh ios`. Bez CloudKit, bez
powiadomień. Team ID w `Local.xcconfig`, poza repozytorium.
