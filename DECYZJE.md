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

**Wynik pojedynku zależy od zaskoczenia, nie od samego zwycięstwa.**
Stały krok 0,25 psuł się przy dużych seriach na dwa sposoby naraz. Zwycięzca
serii 22-elementowej wygrywał 21 razy i wychodził na sufit skali — zmierzone:
przy stałym kroku każda seria od 12 zdjęć w górę kończy się piątką. Drugi błąd
był cichszy i groźniejszy: **przegrany tracił zawsze tyle samo**, więc
„przegrało z najlepszym w serii" i „przegrało z byle czym" trafiały do składu
jako ta sama liczba.

Wygrana z równym sobie daje pełny krok, z wyraźnie słabszym prawie nic — od
faworyta oczekuje się wygranej, więc nic nowego się nie dowiadujemy. Lider
przestaje zarabiać w miarę wzrostu, więc sufit znika sam, bez sztucznego
ograniczania. Po zmianie: seria 5 → 3,12, seria 22 → 3,60, seria 40 → 3,75.

Do tego **malejący krok od liczby ocen** (`0,5 / (1 + judgements/10)`):
zdjęcie oglądane dwadzieścia razy ma ustaloną pozycję i nie powinno skakać po
jednym pojedynku. Swipe świadomie tego nie używa — tam decydujesz wprost
i ruch ma być ruchem, a nie negocjacją z historią.

Odrzucona alternatywa: przeliczanie serii na miejsca po jej zakończeniu
(pierwszy dostaje 5, ostatni 1). Niszczy porównywalność między seriami —
piąte miejsce wśród świetnych zdjęć dostałoby tyle samo, co piąte wśród
nieudanych.

**Postęp turnieju mieszka w składzie, nie w widoku.** Wcześniej lider
i numer pretendenta były `@State`, więc wyjście w połowie serii kasowało całą
pracę. Przy trzech zdjęciach niewidoczne, przy dwudziestu kosztowne — a duże
serie są powodem, dla którego ten tryb istnieje.

**Odrzucenie serii jest osobne od pominięcia.** Pominięcie znaczy „nie teraz",
odrzucenie — „algorytm się pomylił". Odsetek odrzuceń mówi wprost, czy próg
czułości jest źle ustawiony.

## Miejsce na dysku

PhotoKit **nie ma API do usuwania lokalnych oryginałów**. Sterować można
wyłącznie popytem, więc prefetch na iOS ma **wyłączoną sieć** — inaczej
przeglądanie archiwum kopiowałoby iCloud na telefon.

Rozważane i odrzucone: wymuszanie presji na dysk, żeby system sam posprzątał.
Działa, ale nie da się wycelować, na iOS czyści najpierw własną aplikację,
grozi utratą cudzych danych i opiera się na nieudokumentowanym zachowaniu.

## Interfejs

**Wspólny jest model, nie sposób obsługi.** Nie chodzi o szerokość okna —
szerokość to tylko objaw. Chodzi o to, że jedną platformą steruje klawiatura
i wskaźnik, a drugą kciuk; że na Macu pojedyncze kliknięcie należy się
zaznaczaniu, a na telefonie nie ma czego zaznaczać.

Ten sam błąd wrócił pięć razy w pięciu przebraniach: poziomy pasek rozsypany
na jedną literę w wierszu, `Picker` zwijający `Menu`, popover przypięty do
znikającej kotwicy, `Form` bez własnego tła, dwuklik tam, gdzie wystarczy
stuknięcie. Za każdym razem wyglądało na nowy problem i za każdym razem
przyczyną było przeniesienie cudzego idiomu zamiast napisania własnego.

Każdy widok ma własny chrome pod `#if os(…)`. Wspólne są dane i decyzje.

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

**W bok przewijasz, w pionie oceniasz.** Pierwsza wersja miała to odwrotnie,
z apek randkowych — i sprawdziła się źle. Radek chciał przewinąć zdjęcie
i wystawił mu ocenę. To nie kwestia gustu: **błąd idzie tu w kosztowną
stronę**, bo zostawia w skali wpis, którego nikt nie zamierzał, a pomyłka
odwrotna nie kosztuje nic.

Trzy powody, dla których ten podział jest właściwy. **Częstotliwość** —
przez zdjęcia przechodzi się stale, ocenia rzadziej, więc najczęstsza
czynność zasługuje na najbardziej odruchowy gest. **Konwencja** — poziomy
swipe to przewijanie w każdej galerii; apki randkowe są wyjątkiem, w którym
ruch w bok *też* znaczy „następna", tylko z doklejonym werdyktem.
**Semantyka** — pion pasuje do wartości (w górę więcej), poziom do kolejności.

Ocena **przechodzi dalej za jednym zamachem**. Bez tego odsiew kosztowałby
dwa ruchy zamiast jednego i cała szybkość by wyparowała.

Oś rozstrzyga **przewaga** jednego kierunku nad drugim, nie sam próg: palec
nigdy nie idzie prosto i ukośny ruch potrafiłby ocenić i przeskoczyć naraz.

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

## Synchronizacja

Dwa transporty obok siebie, bo robią co innego. **Albumy Photos
`lightbrary ★1`…`★5`** pokazują gwiazdki w systemowych Zdjęciach — to jedyny
sposób, żeby ocena była widoczna poza tą aplikacją. Jedzie przez nie
**gwiazdka, nie pełna waga**: dwadzieścia albumów po 0,25 zaśmieciłoby
bibliotekę. Słowa kluczowe odpadają, bo PhotoKit ich nie zna.

**Plik wymiany** przenosi całą resztę: dokładną wagę, liczbę ocen, odciski
i stan turniejów.

*Nieaktualne od września 2026:* albumy `★1…★5` zastąpiło `PHAsset.rating`,
oznaczenie do skasowania jedzie albumem „lightbrary – to delete", a pliki
wymiany są trzy (schemat 5). Stan obecny: „Podział: eksporter poza sklepem,
przeglądarki w sklepie".

Transportem jest **plik w folderze wskazanym przez użytkownika**, zwykle
w iCloud Drive. CloudKit i własny kontener iCloud wymagają płatnego konta.
Zwykły folder synchronizuje się sam, nic nie kosztuje i jest widoczny — można
tam zajrzeć, skopiować, usunąć. Odczyt idzie przez `NSFileCoordinator`, więc
działa też z Google Drive i OneDrive, nie tylko z iCloud.

**Jeden plik na urządzenie, nigdy wspólny.** Do wspólnego pisałyby oba naraz,
a chmura rozstrzyga takie zapisy kopiami konfliktowymi. Przy podziale per
urządzenie konflikt nie ma jak powstać; scalanie dzieje się przy czytaniu.

Format to SQLite: 25 tysięcy wektorów to 39 MB danych binarnych, które w JSON
urosłyby o jedną trzecią. Zapytania kompilujemy raz na tabelę — wersja
z kompilacją per wiersz zapisywała plik pół minuty.

### Plik nieściągnięty nazywa się inaczej niż ściągnięty

iCloud Drive pokazuje plik, którego jeszcze nie pobrano, jako **znacznik
zastępczy** o nazwie `.nazwa.ibsync.icloud` — z kropką z przodu i cudzym
rozszerzeniem. Filtr po samym `ibsync` przelatywał obok, więc telefon stojący
dokładnie nad plikiem Maca meldował „nie znalazłem plików z innych urządzeń".

Na Macu to nigdy nie wyszło, bo tam wszystko było od dawna na dysku. Błąd
czekał na pierwsze urządzenie, które dostaje plik, jakiego jeszcze nie ma.
Ze znacznika odtwarzamy prawdziwą nazwę; gdy pliku fizycznie nie ma, prosimy
o pobranie wprost, bo koordynator potrafi odpowiedzieć szybciej, niż dostawca
zdąży dostarczyć dziesiątki megabajtów.

Etykieta mówi **„pobieram"** albo „czytam" zależnie od tego, co się dzieje —
to są różne oczekiwania i wcześniej nie dało się ich odróżnić.

Sprawdzenie stanu wysyłki od strony systemu: `URLResourceKey`
`.ubiquitousItemIsUploadedKey` i `.ubiquitousItemDownloadingStatusKey`.
Bez tego nie sposób odróżnić „chmura jeszcze nie skończyła" od błędu w kodzie
— a przy pliku 59 MB pierwsze zdarza się często.

### Zakładka do folderu przestaje obowiązywać wraz z tożsamością aplikacji

Po zmianie konta deweloperskiego zakładka wystawiona poprzedniemu podpisowi
nie działa i nigdy już nie zacznie. Gorsze było to, że `isChosen` sprawdzało
wyłącznie istnienie danych zakładki: menu twierdziło „folder wybrany",
a synchronizacja prosiła o wskazanie folderu, który widniał jako wskazany.
Zakładkę nie do odzyskania **zapominamy**, żeby interfejs mówił prawdę.

### `localIdentifier` nie jest wspólny między urządzeniami

To był najdroższy błąd tego projektu i wyszedł tylko dlatego, że raport
pokazywał liczby: telefon zgłosił **32 819 odcisków przy 24 984 zdjęciach**.
7 835 własnych plus 24 984 z Maca, bez ani jednego trafienia we wspólne
zdjęcie.

`PHAsset.localIdentifier` jest lokalny — nazwa nie kłamie. To samo zdjęcie
z tej samej biblioteki iCloud ma inny identyfikator na Macu i na telefonie.
**`PHCloudIdentifier`** jest tym, czym `localIdentifier` nie jest, i Apple
dodało go dokładnie do tego zadania. Plik wymiany nosi wyłącznie takie
identyfikatory; każde urządzenie tłumaczy je na swoje przy zapisie i odczycie,
jednym mapowaniem odwracanym w pamięci.

Dotyczy to również **kluczy serii**: klucz to skład grupy, czyli identyfikatory
zdjęć — a więc dokładnie ta rzecz, która się różni. Ta sama pułapka, drugi raz,
piętro wyżej.

### Reguły scalania

- **Odciski** — bierzemy brakujące. Vision jest deterministyczny, więc cudzy
  wektor jest tak samo dobry jak własny. To największy zysk: telefon nie mieli
  25 tysięcy zdjęć, skoro Mac już to zrobił.
- **Oceny** — wygrywa nowsza. Przy przepisywaniu cudzej decyzji zapisujemy
  wprost, nie przez `set()`, bo tamto policzyłoby cudzą pracę jako własną.
- **Serie** — po składzie grupy. Zmiana czułości sama unieważnia stare werdykty.

**Plik przed albumami, nie po.** Album niesie samą gwiazdkę i stempluje ją
bieżącym czasem, więc puszczony pierwszy wygrywa z dokładną wagą z pliku
i podmienia 3,75 na okrągłe 4.

**Rozstrzygnięcia serii muszą przeżyć przeliczenie grup.** Przebudowa kasowała
serie razem z całą pracą turniejową, a dzieje się przy każdym nowym odcisku
i każdym ruchu suwakiem czułości — wystarczyło zsynchronizować urządzenia, żeby
stracić wszystkie pojedynki. Werdykt przenosimy po kluczu składu.

**Sprzątanie sierot** przy każdej synchronizacji: odciski i serie wskazujące
na nieistniejące zdjęcia. Powstają zwyczajnie po skasowaniu zdjęcia,
a nadzwyczajnie — po błędzie takim jak ten powyżej.

### Raport pokazuje obie strony

„Wczytano 0" nie odróżnia „nie znalazłem pliku" od „znalazłem, ale wszystko już
mam". Raport podaje, ile plik oferował, ile z tego było nowe i ile jest łącznie
— i to właśnie ta trzecia liczba ujawniła błąd z identyfikatorami.

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

## Cechy policzone przez system

Pod biblioteką leży znacznie więcej, niż pokazuje aplikacja Zdjęcia: 89 tabel,
a w nich ostrość każdego zdjęcia, jakość ekspozycji, 18 781 wykrytych twarzy
z miną, wiekiem i stanem oczu, oraz 1,24 mln etykiet scen. Wszystko policzone,
gotowe i **za darmo** — dokładnie te rzeczy, które sami liczylibyśmy tygodniami.

Stąd czwarty tryb: przeglądy poprzeczne cudzą miarą. Nie ocena — **zestawienie**.
Żadna z tych liczb nie dotyka wagi zdjęcia.

### Sekcja cech musi być otwarta — i musi się sama dowiadywać

Powód jest od Radka: **nie wiemy, co jeszcze da się wyciągnąć z tej bazy,
a ponadstandardowe przekroje przez bibliotekę są tym, po co ta aplikacja
istnieje.** Do tego kolumny to po części artefakty przeszłości, po części
zapowiedzi przyszłości, i będzie się to zmieniać z każdą wersją systemu.

### Najpierw pomyłka, bo ona jest tu argumentem

Pierwszy spis zrobiliśmy pytaniem „ile zdjęć ma wartość **większą od zera**"
i wyszło, że pokrycie jest bardzo różne: kompozycja 11 517, ikoniczność 7 709,
a szum, „nieudane ujęcie" i „natrętny obiekt" **zerowe**, czyli nieużywane.

To było fałszywe od początku do końca. Te kolumny są **znakowane**, a trzy
rzekomo puste są wypełnione w całości wartościami **ujemnymi**: szum ma zakres
−0,942…0, „nieudane ujęcie" −0,712…0, „natrętny obiekt" −0,989…0. Zero jest
tam najlepszym możliwym wynikiem, nie brakiem wyniku.

Po poprawnym zmierzeniu obraz jest odwrotny do pierwszego: **prawie wszystko
jest wypełnione dla całej biblioteki** — 26 028 do 26 129 zdjęć z 26 123.
Jedyną naprawdę pustą kolumną jest `ZPROMOTIONSCORE`.

### Co naprawdę różni te kolumny

Nie pokrycie, tylko **konwencja**. A ta jest za każdym razem inna:

- **0…1**, wyżej znaczy lepiej: kuracja, estetyka ogólna, widoczność
  we wspomnieniach, aktywność, immersyjność, wzory, symetria, ostrość tematu,
  przydatność na tapetę;
- **0…1, ale nazwa kłamie**: `ZBLURRINESSSCORE` rośnie wraz z **ostrością**
  (osobny rozdział wyżej);
- **−1…1**, symetryczne: kompozycja, oświetlenie, ciekawy temat, żywe kolory,
  ładne rozmycie tła, dobrze wybrany i dobrze skadrowany temat, dobry moment,
  perspektywa, odbicia, obróbka, harmonia kolorów;
- **−2…1**, niesymetryczne: ikoniczność;
- **tylko ujemne, zero najlepsze**: szum, nieudane ujęcie, natrętny obiekt
  w kadrze, przechył kadru (−0,217…0,076);
- **−1 jako znacznik „nie dotyczy"**: `ZSETTLINGEFFECTSCORE`
  i `ZVIDEOSTICKERSUGGESTIONSCORE` mają −1 dla 25 921 zdjęć, bo dotyczą wideo.

Czyli **„brak danych" ma w tej bazie trzy różne zapisy**: brak wiersza, zero
i minus jeden. Którą konwencję ma dana kolumna, nie wynika z niczego, co da się
odczytać z danych.

### Stąd podział: sonda dynamiczna, znaczenie kurowane

Czego aplikacja **może dowiedzieć się sama**, przy każdym wczytaniu cech:

- czy kolumna w ogóle istnieje w tej wersji systemu — dzięki temu zniknięcie
  kolumny przestaje być awarią, a pojawienie się nowej daje się zauważyć;
- ile zdjęć ma wartość, ile zer, ile wartości ujemnych;
- rzeczywisty zakres i rozkład — a z tego **granice suwaka progu**, zamiast
  sztywnych 0,1–1,0, które dla kolumny o zakresie −0,217…0,076 nie znaczą nic;
- czy warto pokazać wiersz: kolumna stała w całym archiwum nie jest przekrojem.

Czego aplikacja **nie ma jak zgadnąć** i co musi być zapisane ręcznie:

- nazwa po ludzku — `ZPLEASANTCAMERATILTSCORE` to nie jest etykieta;
- kierunek: czy wyżej znaczy lepiej, czy gorzej;
- co znaczy zero i czy istnieje wartość-znacznik;
- czy miara jest ciągła, licznikiem, czy przełącznikiem.

Znaczenia nie da się odkryć — to jest ta sama lekcja, co przy
`ZBLURRINESSSCORE`, tylko w większej skali. **Dynamiczna jest obecność
i kształt, kurowane jest znaczenie.**

### Kolumna milcząca milczy z trzech różnych powodów

Doprecyzowanie od Radka, bez którego cała rzecz byłaby o połowę mniej warta:
w schemacie leżą **wymiary kiedyś zaimplementowane i porzucone** oraz takie,
**które Apple dopiero planuje wdrożyć**. Jedne i drugie wyglądają identycznie:
kolumna jest, wartości nie ma.

Rozróżnia je jedno pytanie — `count(distinct)`:

| kolumna | różnych wartości | co to jest |
|---|---|---|
| `ZRATING` | 1 (samo zero) | gwiazdki z iPhoto i Aperture, martwe od lat |
| `ZPROMOTIONSCORE` | 1 (samo zero) | istnieje, nigdy nie wypełniona |
| `ZHIDDEN` | 1 (samo zero) | kolumna żywa — to **ta biblioteka** nic nie ukrywa |
| `ZFAVORITE` | 2 | żywa, 26 zdjęć |
| `ZSTICKERCONFIDENCESCORE` | 2 375 | naklejki: świeża funkcja systemu, **już zapalona** |

Jedna wartość w całym archiwum znaczy „brak sygnału" i to da się zmierzyć.
Ale **dlaczego** go nie ma — bo funkcję porzucono, bo jej jeszcze nie wdrożono,
czy bo ten użytkownik po prostu takich zdjęć nie ma — tego z danych nie wynika.

Najważniejsze jest to, że **ten stan się zmienia w czasie**.
`ZSTICKERCONFIDENCESCORE` byłby dwa lata temu martwy; dziś niesie 2 375 różnych
wartości. Kolumna milcząca dziś może odezwać się po aktualizacji systemu albo
po tym, jak analiza po stronie Apple dogoni archiwum.

Z tego wynikają dwie rzeczy, których pierwsza wersja tego rozdziału nie miała:

- **sonda ma chodzić przy każdym wczytaniu cech**, nie raz na zawsze przy
  pisaniu kodu — inaczej zapalona kolumna nigdy się nie ujawni;
- **sonda ma umieć zgłaszać kolumny, których nie zna**. Gdy w schemacie
  pojawi się nowa miara z realnym rozkładem, aplikacja powinna o tym
  powiedzieć, a nie czekać, aż ktoś zajrzy do bazy z ciekawości. Wtedy
  „artefakt przyszłości" zamienia się w nową oś przeglądu bez wydawania nowej
  wersji — wystarczy dopisać mu nazwę i kierunek.

Odwrotna strona tej samej reguły: miara pusta **w tej bibliotece**, a nie
w ogóle — jak zrzuty ekranu u kogoś, kto ich nie robi — ma zostać widoczna
z licznikiem zero. Brak wyników jest informacją. Dlatego spis kurowany dzieli
miary na **rdzenne**, pokazywane zawsze, i **znalezione**, pokazywane tylko
wtedy, gdy mają rozkład.

### Które wymiary są na wierzchu, zależy od człowieka i od zadania

Roleta nie jest sposobem na schowanie nadmiaru. Jest sposobem na to, żeby na
wierzchu stało to, czego **ten** użytkownik używa — a to co innego u kogoś, kto
przegląda wakacje, co innego u drugiego fotografa, i co innego przy sesji
sprzątania. Wymiar rdzenny dla jednej osoby jest dla drugiej martwy.

Stąd kolejność ma być **ręczna, nie samoucząca**. Automatyczne wypychanie
najczęściej używanych na wierzch jest kuszące i byłoby błędem: lista, po której
chodzi się z pamięci, nie może się przestawiać sama. Najwyżej podpowiedź
przy często używanym wierszu.

### Miara dotyczy albo obrazu, albo jego historii

Przy dwudziestu kilku pozycjach lista potrzebuje podziału, a naturalny podział
nie idzie wzdłuż typu danych, tylko wzdłuż tego, **czego miara dotyczy**:

- **właściwości zdjęcia** — ostrość, naświetlenie, kompozycja, kolor, twarze,
  przechył kadru. Trwałe: zdjęcie nieostre będzie nieostre zawsze;
- **stan w archiwum** — nigdy nieoglądane, kiedyś udostępnione, ulubione,
  w serii, duplikat, zrzut ekranu. To nie są cechy obrazu, tylko jego historii;
- **technika** — HDR, portret, wideo, rozdzielczość, brak lokalizacji.

Podział jest praktyczny, bo grupy odpowiadają różnym zadaniom: pierwsza służy
ocenianiu jakości, druga sprzątaniu, trzecia szukaniu konkretnego materiału.

### Niektóre warunki starzeją się razem ze zdjęciem

Obserwacja Radka po wieczorze kasowania zrzutów ekranu: **zrzut ma wartość
głównie wokół daty powstania**. Sprzed tygodnia to notatka, sprzed pięciu lat
śmieć. To samo dotyczy „nigdy nieoglądanych" — świeże zdjęcie jeszcze
nieobejrzane nie znaczy nic, sprzed dziesięciu lat znaczy wszystko.

Takie warunki chcą domyślnie wchodzić **razem z warunkiem wieku**. Inaczej
trzeba ustawić dwie rzeczy naraz, a nikt tego nie zrobi, dopóki sam na to nie
wpadnie.

### Poziom wyżej: zapisany zestaw warunków

Sesja kasowania zrzutów to nie jeden wymiar, tylko kombinacja: zrzuty, starsze
niż jakiś czas, po dacie, z operacją na całej puli na końcu. Takich
powtarzalnych zestawów będzie kilka i będą różne u różnych osób — czyli roleta
rozwiązuje warstwę niżej, niż leży prawdziwa potrzeba.

Do rozstrzygnięcia przy następnej turze projektu: czy zapisany zestaw warunków
to osobne pojęcie, czy część „przestrzeni roboczej" razem z układem paneli.
Jedna kontrolka mniej to zysk, ale zlepienie dwóch różnych pojęć mści się
później.

### Skoki w rozkładzie: czwarty zapis „braku zdania"

Kuracja ma **17 882 zdjęcia — prawie 70% biblioteki — z wartością dokładnie
0,5**. Ikoniczność ma 1 652 zdjęcia na samym minimum, −2. To wygląda na zapis
„system nie ma zdania", tylko tym razem w środku skali albo na jej krańcu,
a nie na zerze. Do trzech znanych zapisów braku danych (brak wiersza, zero,
minus jeden) dochodzi więc czwarty: **wartość-wypełniacz w skoku rozkładu**.

Wyszło to przez licznik: domyślny przedział „najgorsza dziesiąta część"
kuracji obiecywał 18 847 zdjęć. Dziesiąty centyl wpadał w środek skoku,
a przedział „do 0,5 włącznie" zgarniał go w całości.

Cięcie domyślne jest teraz odporne na remisy: gdy wartość graniczna należy do
skoku, który rozdmuchałby wynik ponad dwukrotność celu, schodzi na najbliższą
wartość przed skokiem. Sprawdzone na bibliotece: kuracja 5,5% zamiast 72%,
miary bez skoków bez zmian — równo 10%.

Nie traktujemy tych wartości jako braku pomiaru, bo to byłoby zgadywanie.
Histogram pod suwakiem pokazuje skok wprost i to wystarczy, żeby go ominąć.

### Konsekwencja dla przechowywania

Dziś cechy to sześć pól w `Review` i dwanaście kolumn w pliku wymiany. Przy
czterdziestu miarach, z których część przybędzie po aktualizacji systemu, każde
dołożenie znaczyłoby migrację składu i podbicie formatu wymiany. To się nie
skaluje.

Właściwym kształtem jest **jeden blob na zdjęcie**: spakowany słownik
`klucz → wartość`, dokładnie tak jak `Fingerprint.vector` trzyma wektor
w half-floatach. Zgodność idzie wtedy w obie strony — starsza wersja czyta
nowszy plik i pomija nieznane klucze, nowsza czyta starszy i widzi ich mniej.
Koszt: czterdzieści miar na 26 tysięcy zdjęć to około 2 MB w half-floatach,
wobec 39 MB odcisków, które i tak jeżdżą w każdym pliku wymiany.

Uboczny zysk: klucz cechy przestaje być `rawValue` polskiego enuma, więc znika
problem zapisany niżej — nazwa wyświetlana może się tłumaczyć, bo nie jest już
kluczem zapisu.

### Jak to zostało zrobione

**Spis w kodzie, obecność w bazie.** `Measure.all` trzyma 38 miar: kod, nazwę,
grupę, rodzaj (ciągła albo przełącznik), kierunek i wyrażenie SQL. Przy
wczytywaniu każde wyrażenie jest najpierw sprawdzane pustym zapytaniem —
jeśli się nie kompiluje, kolumny nie ma w tej wersji systemu i miara po prostu
wypada. Potem jedno zapytanie na całą bibliotekę, nie jedno na miarę.

**Jedno pole w `Review`.** Miary jadą spakowane: pięć bajtów na wpis, kod
i wartość. **Kody są stałe na zawsze** — starsza wersja pomija nieznane,
nowsza przy starym pliku znajduje ich mniej, i nie trzeba żadnej migracji.
Przełączniki zapisujemy tylko wtedy, gdy są prawdą.

**Plik wymiany w wersji 4, czytający też 3.** Wcześniej odczyt wymagał
dokładnej równości wersji, więc telefon ze starszą aplikacją i Mac z nowszą
przestawały się widzieć, dopóki oba nie dostały aktualizacji.

**Wartości w tablicy, nie w słowniku.** Liczniki w panelu sprawdzają wszystkie
miary dla każdego zdjęcia przy każdej zmianie warunków — kilkaset tysięcy
odczytów. Indeks w tablicy kosztuje tyle co nic, haszowanie klucza już nie.

**Próg z pomiaru.** Domyślny próg każdej miary ciągłej to granica najgorszej
dziesiątej części zdjęć tej biblioteki, a suwak ma końce z rzeczywistego
minimum i maksimum. Dzięki temu licznik przy wierszu mówi coś, zanim ktoś
ruszy suwak.

**Cecha i miara to jedna lista wyboru**, tylko w dwóch miejscach panelu:
wybranie jednej zdejmuje drugą. Gdyby mogły działać naraz, liczniki przy
wierszach musiałyby odpowiadać na pytanie o kombinację, której nikt nie widzi.

**Sprawdzone na prawdziwej bazie przed pierwszym uruchomieniem:** wszystkie 38
wyrażeń się kompiluje i każde niesie sygnał.


## Przygotowanie do App Store

Wzorzec przepisany z `FlipClock` — aplikacji, która już przeszła przez sklep.
Wymyślanie tego od nowa nie miało sensu.

### Manifest prywatności jest warunkiem wgrania, nie ozdobą

`Resources/PrivacyInfo.xcprivacy` idzie do obu targetów. Powód jest prozaiczny:
aplikacja używa `UserDefaults` w czterech miejscach, a to jest API „wymagające
podania powodu". Bez manifestu App Store Connect odbija wgranie komunikatem
ITMS-91053, zanim jakakolwiek recenzja się zacznie.

Zadeklarowane są dwa powody, `1C8F.1` i `CA92.1` — dostęp do własnych danych
aplikacji. Sprawdziliśmy resztę listy: **żadne inne API z tej kategorii tu nie
występuje**, w szczególności nie ma dat plików ani wolnego miejsca na dysku.
Jedyne dotknięcie systemu plików to rozmiar pliku wymiany, a ten nie jest na
liście.

Manifest mówi też to, co jest prawdą i co trzeba powtórzyć w kwestionariuszu
App Privacy: **nie śledzimy i nie zbieramy żadnych danych**.

### `ITSAppUsesNonExemptEncryption`

Bez tego klucza App Store Connect pyta o zgodność eksportową przy **każdym**
wgraniu i build wisi, dopóki ktoś nie odpowie ręcznie w przeglądarce.
Aplikacja nie ma własnej kryptografii ani sieci, więc odpowiedź brzmi „nie"
i można ją zapisać raz, w `Info.plist`. Tylko iOS — wersja na Maca nie idzie
przez sklep.

### Numer buildu

`CURRENT_PROJECT_VERSION` podnosi się ręcznie przed wysyłką, tak jak
w `FlipClock`. Każde wgranie musi mieć inny numer, inaczej App Store Connect
je odrzuca. Automat kusi, ale przy kilku wydaniach na rok ręczna liczba jest
uczciwsza niż licznik commitów, który rośnie od rzeczy niezwiązanych
z wydaniem.

### Rekord w sklepie

Założony 16 września 2026: **Lightbrary**, app id `6812906504`, bundle id
`pl.3210.lightbrary`. Nazwa jest zarezerwowana, ale **jeśli do 90 dni nie
pójdzie żaden build, Apple może ją zwolnić** — wystarczy cokolwiek, choćby do
testowania wewnętrznego.

Rekordu aplikacji nie da się założyć przez API; to jedyna operacja zostawiona
wyłącznie w przeglądarce. Klucz API (Team Key, rola App Manager) leży poza
repozytorium, w `~/.appstoreconnect/`, a `.gitignore` ma `*.p8` na wypadek,
gdyby kiedyś znów tam trafił.

## Nazwa kolumny potrafi znaczyć odwrotność

`ZMEDIAANALYSISASSETATTRIBUTES.ZBLURRINESSSCORE` brzmi jak rozmycie, a rośnie
wraz z **ostrością**. Rozstrzygnęło dopiero obejrzenie zdjęć z obu krańców
skali: przy 0,37 wyszło poruszone zdjęcie z garażu, przy 0,999 ostry portret.
Statystyka tego nie pokazała — średnia 0,88 przy maksimum 1,0 wyglądała
sensownie w obie strony.

Morał ogólniejszy: żadnej z tych nazw nie należy wierzyć bez obejrzenia
skrajnych przypadków. To są nazwy wewnętrzne, nigdy nieprzeznaczone dla nikogo
z zewnątrz.

Sprawdzona ślepa uliczka: `ZOVERALLAESTHETICSCORE`. Zestawiona z prawdziwymi
ocenami **nie układa się monotonicznie** — jedynki wypadły wyżej niż trójki.
To ocena estetyczna, nie miara jakości, i jako sygnał do odsiewu nie działa.

### Zero znaczy „nie policzono"

Analiza chodzi, gdy Mac jest bezczynny i pod prądem, więc część wierszy zawsze
czeka w kolejce z dokładnym zerem. Przy sortowaniu rosnąco zajęłyby cały
początek wyniku — czyli pierwszym, co widać, byłyby zdjęcia bez pomiaru.
Dlatego wszędzie odrzucamy dokładne zero jako brak danych.

Podobna pułapka obok: `ZLATITUDE` jest wypełniona dla wszystkich zdjęć, ale
`-180` to wartownik „bez lokalizacji" — u Radka 6 952 zdjęcia. Policzone
naiwnie wysyłają czwartą część archiwum na antypody.

### Transport: cechy jadą w ocenie

iOS nie ma dostępu do tych baz — piaskownica nie wpuszcza do pakietu
biblioteki. Telefon musiałby liczyć wszystko sam albo dostać gotowe.

Cechy są więc **polami w `Review`**, a nie osobnym modelem. Powód jest jeden
i praktyczny: plik wymiany wozi już oceny po identyfikatorach chmurowych, więc
cecha dopisana tam jedzie istniejącą rurą — bez nowej tabeli i bez drugiej
ścieżki scalania. Koszt zmierzony: komplet cech zdjęć i twarzy to **9,9 MB**
wobec 39 MB odcisków, które i tak jadą. Sceny (27 MB) zostają na Macu.

**Pomiar systemu nie uczestniczy w „wygrywa nowszy".** To jest sedno i jedyne
miejsce, gdzie łatwo o cichą utratę danych. Gdyby cechy jechały razem z oceną,
Mac wysyłałby tysiące pustych ocen ze świeżą datą, a każda taka — będąc nowszą
— skasowałaby ocenę postawioną wcześniej na telefonie. Obowiązuje więc „kto ma,
ten daje": cechy przepisują się **przed strażą czasu i niezależnie od niej**,
pusty pomiar nie nadpisuje niczego.

Rekord założony wyłącznie po to, by nieść cechy, ma `isRated == false` i nadal
liczy się jako nieoceniony — filtry pytają o `isRated`, nie o istnienie wpisu.

*Zastąpione w schemacie 5:* cechy nadal mieszkają lokalnie w `Review`, ale
w transporcie mają własny plik `-features` i własne scalanie. Reguła „kto ma,
ten daje" przestała być wyjątkiem w scalaniu ocen — jest po prostu zasadą
scalania cech. Mac, który wczytał cechy przed tą wersją, nie napisze `-features`,
dopóki nie wczyta ich ponownie („load measures").

### Gęsty skład przewraca wzorce pisane dla rzadkiego

Po imporcie `Review` urosło z 461 do 25 172 rekordów i natychmiast wyszło, że
cały projekt stał na cichym założeniu o **rzadkości** tego składu. Widoki
budowały słownik ocen we właściwości obliczanej — przy pół tysiąca rekordów
darmowe, przy 25 tysiącach zabójcze, bo ciało widoku sięga po nie kilka razy.
W ocenianiu jedno naciśnięcie klawisza liczyło kilkaset tysięcy operacji.

Dwie zasady, które z tego zostają:

- Widoki, które pytają o **decyzje**, biorą `@Query` zawężone predykatem do
  `isRated || markedForDeletion`. Zapis pozostaje bezpieczny, bo idzie przez
  `Review.upsert`, szukające po `assetID` niezależnie od zapytania.
- Zestawienie cech liczy się **raz na zmianę warunków**, do `@State`, ze zwłoką
  po ustaniu ruchu suwakiem — inaczej każda klatka przeciągania sortuje 26
  tysięcy zdjęć.

Zestawienie chodzi po **tym samym zbiorze, co ocenianie** (czyli przez filtry).
Inaczej kliknięcie w zdjęcie spoza zawężenia nie trafiało w nic: wskaźnik
zostawał na miejscu i otwierało się zupełnie inne zdjęcie.

### Co siedzi w scenach

Hierarchiczna taksonomia oparta na Wikidanych, nie płaska lista tagów. Słownik
jest w systemie: `PhotosFormats.framework/Resources/PFSceneTaxonomyData_99.bz2`
— 3 515 węzłów, 3 333 krawędzie rodzic–dziecko, do tego `scenetaxonomy.loctable`
z nazwami w 42 językach. Łańcuch to numer sceny → kod Wikidata → nazwa.

Pewność rozstrzyga wszystko: bez progu wychodzi 47,9 etykiety na zdjęcie, przy
0,9 zostaje **4,7**. Dopiero to jest materiał do pokazania człowiekowi. Nazwy
gotowe do wyświetlenia i tak leżą w `psi.sqlite`, który już czytamy.

### Rozmiary — co czyni bazę wielką

Z 992 MB nic ciekawego nie waży prawie nic:

| Co | Rozmiar |
| --- | --- |
| Dziennik zmian (`ACHANGE`, `ATRANSACTION` + indeksy) | 258 MB |
| Wektory i blobi (odciski scen i twarzy, OCR, metadane iCloud) | 258 MB |
| Klasyfikacja scen z indeksami | 160 MB |
| **Właściwości skalarne** | **36 MB** |

Największy kawałek to historia synchronizacji z chmurą — nie dane o zdjęciach.

### Dystrybucja: to nie wejdzie do App Store

Mac App Store wymaga piaskownicy, a aplikacja w piaskownicy nie dostanie
Pełnego dostępu do dysku. Na iOS pakietu biblioteki nie widać w ogóle. Zostaje
**Developer ID i notaryzacja**, czyli dystrybucja poza sklepem — notaryzacja
skanuje pod kątem złośliwego kodu, nie sprawdza zgodności z wytycznymi.

To sugeruje podział, gdyby aplikacja miała kiedyś wyjść do ludzi: **eksporter**
poza sklepem, czytający bazy i zapisujący małą przenośną paczkę, oraz
**przeglądarka**, która działa z tą paczką albo bez niej.

## Jeden zbiór roboczy

### Dwa zbiory to błąd, którego nie da się obejść

Zestawienie cech powstało jako osobna zakładka i było tam najszybszą drogą do
odpowiedzi „czy ten sygnał jest cokolwiek wart". Odpowiedź brzmiała: tak. Ale
zakładka miała wadę, której nie dało się naprawić bez rozbiórki.

Ocenianie chodzi po `filters.apply(...)`. Zestawienie miało własny zbiór:
własny obiektyw, własny próg, własne sortowanie. Kliknięcie w kafelek ustawiało
wspólny wskaźnik i przełączało tryb — ocenianie szukało tego zdjęcia u siebie
i dalej szło **swoją** kolejką. Zgłoszenie brzmiało: „w trybie cecha znajduję
fotkę, wchodzę w zoom, oceniam, następna w kolejce jest fotka z siatki
wszystkie".

Pierwsza poprawka przepuszczała zestawienie przez te same filtry, co ocenianie.
Naprawiała trafienie w kliknięte zdjęcie i nic poza tym — **następne** wciąż
przychodziło z innej kolejki, bo zbioru cech nie da się zapisać w `Filters`
i przenieść przez przełączenie trybu.

Właściwą naprawą było zlikwidowanie drugiego zbioru. Cecha i porządek
przeniosły się do `Filters`, obok roku i stanu oceny, a `FeaturesView` zniknął.
Siatka jest jedna. Kolejka jest jedna. „Poruszone" to warunek, „od poruszonych"
to sortowanie — jedno i drugie widzi każdy tryb.

### Tryb to narzędzie, nie widok

Lista trybów mieszała dwie różne rzeczy: **co oglądam** (siatka, cechy) i **co
robię** (ocenianie, parowanie). Zestawienie cech było więc trybem, choć jest
pytaniem o zbiór — i stąd brała się jego własna kolejka. Po rozdzieleniu
zostały trzy narzędzia: siatka, ocenianie, parowanie. Co oglądam, rozstrzyga
filtr.

Kasowanie **nie** dostało własnego narzędzia, choć się o to prosiło. Decyzja
Radka: wypchnięcie zdjęcia niżej w ocenie pozwala je później wyfiltrować
i skasować hurtem. Jedna skala zamiast skali i osobnego trybu.

### Cechy czytamy raz, do zwykłego słownika

Cechy mieszkają w `Review`, bo tamtędy jadą na telefon. Ale sięganie po nie
przez `@Query` byłoby zabójcze i to z trzech powodów naraz: rekordów z cechami
jest tyle, co zdjęć (25 tysięcy); zapytanie unieważnia widok przy **każdym**
zapisie, więc każda ocena przebudowywałaby siatkę razem ze słownikiem;
a ocenianie celowo pyta tylko o rekordy niosące decyzję i tych pustych nie widzi.

Stąd `FeatureIndex`: jedno pobranie do słownika zwykłych struktur, bez obiektów
modelu. Cechy zmieniają się wyłącznie przy wczytaniu z baz systemu albo przy
synchronizacji — czyli wtedy, gdy ktoś o to wprost poprosi. Wtedy słownik
przeładowujemy jawnie. W trakcie pracy nie zmienia się nic.

### Zbiór roboczy trzymamy policzony, ale nie przeliczamy go przy ocenie

`apply(...)` woła się kilka razy na jedno odrysowanie, bo sięgają po niego
właściwości obliczane. Sortowanie 26 tysięcy pozycji przy każdym z nich
stawiało interfejs — ta sama lekcja, co przy pierwszym wczytaniu cech.
Wynik jest więc zapamiętany pod podpisem z warunków.

Podpis celowo **nie zawiera ocen poszczególnych zdjęć**. Gdyby zawierał, zbiór
przy porządku „od najlepszych" przestawiałby się pod palcem przy każdej ocenie
i zdjęcie uciekałoby spod kursora w trakcie pracy. Zmiana kolejności należy się
zmianie warunków, nie zmianie oceny.

### Brak pomiaru to nie wynik najgorszy

Przy sortowaniu „od poruszonych" zdjęcia bez pomiaru idą na **koniec**, nie na
początek. Zero w bazie znaczy „nie policzono" (patrz rozdział wyżej), więc
wpuszczenie ich przodem dałoby tysiące kadrów, o których nie wiemy nic — czyli
najgorszą możliwą odpowiedź na zadane pytanie. Tak samo nieocenione przy
„od najgorszych": brak oceny nie jest zerem.

### Pasek miniatur: kolejka musi być widoczna

Cały ten błąd sprowadza się do jednego zdania: **kolejka była niewidzialna**.
Wchodziło się w zdjęcie i trzeba było zgadywać, po czym idzie się dalej —
a dowiadywało się dopiero po geście.

Pasek pod zdjęciem pokazuje ten sam zbiór, w tej samej kolejności, z zaznaczoną
bieżącą pozycją i z podpisem miary, która jest w grze. Widać, co będzie
następne, **zanim** zrobisz gest; widać, skąd przyszedłeś; a rozjazd zbiorów
byłby widoczny od pierwszej chwili zamiast do wyśledzenia.

Nie jest mapą całości i nie udaje. Przy 26 tysiącach żaden pasek nie zmieści
archiwum — to okno wokół bieżącego miejsca, wracające na środek przy każdym
kroku. Chowa się klawiszem `T`, bo przy szybkim odsiewie zabiera wysokość,
której na telefonie nie ma.

### Skąd to wzięte

Z rozbioru `lightgallery.js` 1.4.1 — biblioteki, której Radek używa na blogu
i którą wybrał po długim szukaniu. Rozstrzygające było to, że wywołuje ją
**bez jednej opcji**: wszystkie zachowania to wartości domyślne. Czyli nie
zestaw do wyboru, tylko jeden dobrze dobrany zestaw.

Co stamtąd weszło: pasek miniatur jako jedyny sposób na skok dalej niż o jedno
zdjęcie; podpis miary przy miniaturze; obraz idący za palcem z progiem
i odbiciem (to akurat lightbrary miał już wcześniej, doszliśmy do tego osobno).

Co świadomie **nie** weszło: `loop`. Przy 37 zdjęciach z zamku brak ściany jest
miły, przy 26 tysiącach okrążenie archiwum bez ostrzeżenia rozbija całe
założenie „wracasz tam, gdzie skończyłeś".

Czego tamta biblioteka nie ma, a co jest darmowe natywnie: ciągłości
przestrzennej przy otwieraniu — kafel rosnący w zdjęcie. W markupie bloga nie
ma `data-lg-size`, więc `zoomFromOrigin` nie działa i zdjęcie pojawia się bez
związku z klikniętym kafelkiem. Gdyby ten ruch był, opisany wyżej rozjazd
zbiorów byłby widoczny w pierwszej klatce.

## Ocena to jedna skala, nie stan plus skala

Panel miał cztery wiersze stanu — wszystkie, nieocenione, ocenione, do
usunięcia — a pod nimi skalę gwiazdek, **chowaną do czasu wybrania
„ocenionych"**. Radek nie mógł jej znaleźć i to był objaw, nie pomyłka: dwie
kontrolki odpowiadały na jedno pytanie, przy czym drugiej nie dało się
zobaczyć, dopóki nie trafiło się w pierwszą.

Jego obserwacja rozwiązała to lepiej niż odsłonięcie skali: **to jest ten sam
wybór**. Wystarczy jeden rząd siedmiu pozycji — brak oceny, zero i pięć
gwiazdek.

| dawny stan | teraz |
|---|---|
| wszystkie | nic niezaznaczone |
| nieocenione | `brak` |
| ocenione | komplet: zero i pięć gwiazdek |

A przy okazji dochodzi to, czego tamten układ nie umiał wyrazić: sam dół skali,
oceny bez dna, albo nieocenione razem z zerami. Trzy nowe pytania za darmo,
z czterech kontrolek zrobiła się jedna, i nie ma już nic ukrytego pod warunkiem.

**Brak oceny nie jest zerem** i dostaje inny symbol — przekreślone kółko, nie
przekreśloną gwiazdkę. Zero to ocena najniższa z możliwych, czyli dno, na które
wypycha się zdjęcia do skasowania; brak to brak punktu.

**„Do usunięcia" zostało osobno**, bo to nie ocena, tylko decyzja o losie
zdjęcia — i zwykle towarzyszy jakiejś ocenie, zamiast ją zastępować. Gdyby
dzieliło skalę z gwiazdkami, jedno wykluczałoby drugie.

Przy okazji z nagłówka oceniania na telefonie zniknął segmentowany przełącznik
stanu: nie ma już czego dublować.

## Filtr jako widok, nie czynność

### Segmentowany przełącznik nie umie zawieść z godnością

Etykieta z za długim tekstem obcina się wielokropkiem. Menu też. Segmentowany
nie robi nic: nie skraca, nie zawija, nie przewija — wychodzi poza przydzielone
miejsce i znika pod krawędzią. Przy czterech pozycjach stanu oceny ucinał „do
usunięcia" o kilka punktów, a szerokość rośnie liniowo z liczbą pozycji.

Dwie rzeczy z tego wynikają i obie są przyszłe. Liczba kategorii **nie jest
zamknięta** — wystarczy dołożyć jedną cechę. A długość słów zmieni się przy
pierwszym tłumaczeniu, bo żaden inny język nie ma tych samych długości.

Zasada, którą z tego wyciągamy: **pion jest tani i przewijalny, poziom jest
sztywny**. Cokolwiek rośnie z liczbą pozycji albo z długością słów, ma rosnąć
w dół.

### Licznik przy każdym warunku, nie jeden na dole

To jest właściwy powód przebudowy, a szerokość była tylko pretekstem.

Panel miał jeden licznik w stopce i mówił, co wyszło **po** wyborze. Czyli
zawężanie było strzelaniem w ciemno: wybierz, zamknij, zobacz, wróć. Skoro
warunki są wierszami, każdy niesie własną liczbę i odpowiada **zanim**
klikniesz. To jest realizacja „przecinających przeglądów" znacznie bliższa
temu, o co chodziło, niż jakikolwiek przełącznik.

Liczby są **wzajemnie uwarunkowane**: przy ocenach liczymy z nałożoną cechą,
przy cechach z nałożonym stanem oceny. Inaczej wiersz obiecywałby tysiąc zdjęć
i dawał trzy, bo reszta odpadłaby na drugim warunku. Kosztuje to dziewięć
sprawdzeń na zdjęcie, czyli jeden przelot po zbiorze — liczone raz na zmianę
warunków, ze zwłoką, tak samo jak wszystko inne w tej aplikacji.

### Pasek boczny zamiast wyskakującego panelu

Skoro licznik ma odpowiadać przed wyborem, to panel, który trzeba otworzyć,
przeczy sam sobie. Na macOS filtr jest więc kolumną przy krawędzi okna:
liczniki widać cały czas, bez przerywania pracy. Na telefonie zostaje arkusz,
bo tam nie ma z czego wykroić kolumny.

Użyty jest `NavigationSplitView`, a nie własny `HStack` z kreską — z tego samego
powodu, dla którego metadane siedzą w `.inspector`: system sam rysuje materiał
paska, pamięta szerokość, daje się przeciągać i dokłada do belki przycisk
zwijania. Własna kolumna to kolejny drobiazg, który czyta się jako obcy.

Uboczny zysk: w panelu nie ma już ani jednej sztywnej szerokości, więc nie ma
czego przepełnić. Poprzednia wersja obcięła się dwa razy z rzędu — raz po
lewej (`Grid` nie ściska się do tego, co dostaje), raz po prawej (segmentowany
przełącznik zażądał więcej niż 400 punktów).

### Gwiazdki są zbiorem, nie zakresem

Zakres z dwoma końcami wymuszał regułę „pierwsze stuknięcie zwija zakres do
jednej gwiazdki, drugie go rozciąga". Była oszczędna — jeden ruch zamiast dwóch
suwaków — i całkowicie niemożliwa do odgadnięcia z wyglądu kontrolki. Zgłoszenie
brzmiało: „nie rozumiem logiki zaznaczania gwiazdek".

Gorsze było jednak to, czego zakres nie umiał: wybrać trójki i piątki
z pominięciem czwórki. Przy przeglądzie to normalne pytanie.

Teraz każda gwiazdka jest osobnym przełącznikiem, a pusty zbiór znaczy „bez
zawężania", nie „nic" — inaczej odznaczenie ostatniej kasowałoby cały widok
i wyglądało jak awaria.

Przy okazji wyszła cicha luka: `Review.stars` to zaokrąglona waga z zakresu
**0–5**, a stary zakres zaczynał się od jedynki. Zdjęcia wypchnięte na samo
dno — czyli dokładnie te, które wypycha się tam, żeby je potem skasować — nie
pokazywały się w żadnym filtrze. Zero jest teraz pełnoprawną pozycją skali,
z przekreśloną gwiazdką, bo to nie brak oceny, tylko ocena najniższa
z możliwych.

### Co z tego zostaje na później

`rawValue` w `Filters.Feature` i `Filters.Order` jest jednocześnie **kluczem
zapisu w `UserDefaults` i napisem na ekranie**. Dopóki napis jest polski i stały,
działa. W dniu tłumaczenia trzeba to rozdzielić — stabilny `rawValue`
techniczny, osobna etykieta — i zrobić to **przed** tym, jak komukolwiek
zapiszą się preferencje, bo potem wymaga migracji ustawień i zgadywania,
w jakim języku coś zapisano.

Tak samo plakietki na kafelkach: „zrzut" mieści się w kapsule na 92 punktach,
dłuższe tłumaczenie nie. Dla przypadków binarnych odpowiedzią jest symbol
zamiast słowa; liczby zostają liczbami, bo są międzynarodowe.

## Nazwa

Aplikacja nazywała się `ibrowse` — nazwa robocza, generyczna i zajęta
w kilkunastu miejscach naraz. Od września 2026 nazywa się **lightbrary**.

Nazwa niesie dwa czytania i dopiero drugie jest właściwe. Pierwsze, od którego
wyszła, to „odchudzacz biblioteki" — ale to opis etapu, z którego aplikacja
właśnie wyszła. Drugie to **biblioteka światła**, z echem podświetlarki: mebla,
na którym od stu lat rozkłada się klatki obok siebie i wybiera lepsze. To jest
dokładnie opis parowania i paska miniatur.

### Co zmiana nazwy zabiera po drodze

Identyfikator pakietu wyznacza katalog składu i domenę ustawień. Zmiana nazwy
zmienia jedno i drugie, więc bez przygotowania aplikacja po przemianowaniu
zastaje **pustkę**: oceny i cechy zostają pod starą ścieżką, nietknięte
i niewidoczne. Wygląda to jak utrata całej pracy, choć nic nie ginie.

Dlatego przy pierwszym uruchomieniu pod nową nazwą przenosimy skład — wszystkie
trzy pliki, bo SQLite trzyma dziennik zapisu obok bazy — i przygarniamy
ustawienia ze starej domeny. Z ustawień naprawdę bolą dwa: **zakładka do
folderu wymiany**, bo trzeba by go wskazywać od nowa, i **identyfikator
urządzenia**, bo z nowym Mac zacząłby pisać drugi plik wymiany, a stary czytał
odtąd jako cudzy — kilkadziesiąt megabajtów przy każdej synchronizacji, bez
końca.

Na iOS przygarnięcia nie ma i być nie może: stara aplikacja to osobny kontener,
do którego nowa nie ma dostępu. Telefon odzyskuje wszystko synchronizacją,
o ile przed przemianowaniem zdążył wysłać swoją pracę.

### Czego nazwa celowo nie dotknęła

**Nazw plików wymiany i rozszerzenia `ibsync`.** Plik leży w chmurze i ma po
drugiej stronie urządzenie, które o przemianowaniu nie wie. Zmiana nazwy
znaczyłaby, że każde urządzenie zaczyna pisać drugi plik obok swojego starego,
a stary czyta odtąd jako cudzy. Format jest ten sam, więc przemianowanie
kupowałoby wyłącznie spójność nazw, a kosztowało zgodność.

## Ikona

Jeden rysunek, **dwa kadry** — bo platformy chcą czegoś przeciwnego. Na Macu
ikona sama nosi zaokrąglony kształt i margines wokół niego, bo system niczego
nie przycina. Na iOS kanwa musi być wypełniona do krawędzi, bo maskę nakłada
system; ten sam plik dałby tam zaokrąglony kwadracik w białej ramce.

Najlepiej więc mieć **dwa mastery**, po jednym na kadr: `Resources/icon-source.png`
z marginesem i cieniem, `Resources/icon-source-ios.png` wypełniony do krawędzi.
`tools/make-icon.swift` robi z nich komplet.

Gdy drugiego mastera nie ma, narzędzie **znajduje kafelek samo** w pierwszym:
szuka pikseli jaśniejszych od tła wzdłuż środkowego wiersza i środkowej
kolumny, gdzie krawędź jest prosta. Jaśniejszych, a nie „różnych od tła", bo
między tłem a kafelkiem leży cień — ciemniejszy od obu — i łapanie go dawało
kadr o kilka procent za szeroki. To działa, ale gorzej: wycięty kadr niesie ze
sobą cień z brzegów rysunku dla Maca.

Wcześniej kadr opisywała **jedna liczba**, udział szerokości. Zawodziła
z powodu, który widać dopiero po fakcie: kafelek nie musi stać na środku kanwy.
W jednym z rysunków siedział 19 px wyżej, więc każdy wyśrodkowany kadr
zostawiał biały pasek z jednej strony i wcinał się w rysunek z drugiej. Jedna
liczba nie ma jak tego opisać — potrzebny jest prostokąt.

### Przezroczystość: inaczej na każdej platformie

macOS **potrzebuje** alfy. Ikona jest tam rysunkiem swobodnym z własnym
cieniem, a spłaszczona na biało wychodzi w Docku białym kwadratem. iOS alfy
**nie przyjmuje** w ogóle.

Poprzednia wersja spłaszczała na biało wszędzie — i na Macu to był błąd, tylko
niewidoczny, bo ówczesny rysunek miał białe tło i biały kwadrat wtapiał się
w rysunek. Wyszło dopiero przy ikonie z prawdziwą przezroczystością.

Na Macu robimy pełen komplet od 16 px, nie samo 1024: małe kafelki widuje się
częściej niż duże, a skalowane w locie rozmywają się w plamę.

Dock i Finder trzymają ikonę w pamięci podręcznej i nie zauważają zmiany
w pakiecie, więc `install.sh` przerejestrowuje aplikację w LaunchServices.

### Rysunek

Pierwsze dwie wersje były kwiatkiem z ikony Zdjęć Apple z dołożonym własnym
elementem. Do buildów na własnym biurku obojętne; przed czymkolwiek, co idzie
przez recenzję Apple, nie do utrzymania — ikona wyraźnie zbudowana na ikonie
aplikacji systemowej jest odrzucana, a to dokładnie ta kategoria kłopotu,
o którą chodziło w pytaniu „czy mogą za to zablokować developera".

Obecny rysunek jest własny: spektralna płytka i szklana lupa ze znakiem
ćwiartek. Ćwiartki są czytelne także przy 16 px, gdzie spektrum robi się jedną
plamą — i tak ma być.

## Podgląd 1:1

Reszta aplikacji pracuje na podglądach do 2048 px, bo to szybkie i tanie.
Ale **lupka nad podglądem kłamałaby**: pokazywałaby wygładzone powiększenie
i odrzucałbyś ostre zdjęcia jako miękkie. Ostrość jest pierwszym pytaniem przy
odsiewie, więc to jedyne miejsce, gdzie potrzeba prawdziwych pikseli.

Stąd dwie zasady. Oryginał dociągamy **dopiero na żądanie**, nigdy z góry.
A gdy go nie ma, mówimy to wprost, zamiast powiększać podgląd — narzędzie do
oceniania nie ma prawa zmyślać materiału, na podstawie którego decydujesz.

Na Macu wolno dociągnąć z iCloud. Przyrost nie jest wyciekiem, tylko pamięcią
podręczną zarządzaną przez system: gdy zabraknie miejsca, „Optymalizuj pamięć"
eksmituje najstarsze oryginały. Na telefonie **nigdy** — tam pobrany oryginał
zostaje na stałe i nie ma API, żeby go usunąć.

Skala liczona przez skalę ekranu, nie na sztywno: na Retinie bez tego
dostalibyśmy 2:1 i znów oglądalibyśmy interpolację.

## Konwersja do HEIC — właściwe miejsce jest przed importem

Zmierzone na tej bibliotece: **20 568 JPEG-ów zajmuje 56,4 GB**, a HEIC jest
o **40% oszczędniejszy na megapiksel** (0,18 wobec 0,30 MB/Mpx). Nagroda to
około 20 GB, czyli szósta część archiwum. Edytowanych JPEG-ów jest 38, więc
utrata historii edycji praktycznie nie istnieje.

Mimo to **dla istniejącej biblioteki to zły interes**. PhotoKit nie umie
podmienić oryginału w miejscu; trzeba stworzyć nowe zdjęcie i skasować stare,
a wtedy: nowy `localIdentifier` (nasze oceny się odklejają), albumy do
odtworzenia, twarze i etykiety od nowa, chwilowo podwójne zużycie iCloud
i strata generacyjna.

Wszystkie te problemy biorą się z jednego założenia — że konwertujemy zdjęcia
**już będące w bibliotece**. Przy przygotowaniu zbioru **przed wgraniem** nie
ma żadnego z nich: nie ma identyfikatora do zerwania, albumów ani twarzy. Są
pliki na dysku, konwersja i jeden import. Dlatego takiego narzędzia nie było
tam, gdzie Radek go szukał: należy przed biblioteką, nie w niej.

To osobne narzędzie z tej samej rodziny. Zapisane jako pomysł, nie zaczęte.

## Konkurencja: co robią inni, wrzesień 2026

Pierwszy konkretny punkt odniesienia w tej kategorii — `cullibrate.com`, a przez
ich stronę porównań także Photo Mechanic, Narrative, Aftershoot i FilterPixel.
Warto to zapisać, bo dotąd projektowaliśmy bez wiedzy, co robią inni.

### Jak wygląda ta kategoria

Wszyscy robią **narzędzie do sesji zdjęciowej**: wciągnij RAW-y z karty,
przejrzyj, wyślij zaznaczone do Lightrooma lub Capture One. Oś jest zawsze ta
sama — ingest, cull, handoff. Zestaw trybów też: filmstrip, siatka, porównanie
dwóch klatek ze sprzężonym powiększeniem, „survey" czyli kilku kandydatów naraz,
panel twarzy i grupowanie prawie-duplikatów.

Ceny: Photo Mechanic 149 dolarów rocznie, Cullibrate 29 w ofercie
założycielskiej i 120 jako cena docelowa. Rynek istnieje i nie jest groszowy.

Aftershoot i FilterPixel idą w automat — „auto-cull", własne oceny ostrości,
przetwarzanie w chmurze. Cullibrate i Photo Mechanic zostają przy ręcznym
wyborze i sprzedają szybkość oraz to, że decyzja należy do człowieka.

### Co to potwierdza

Trzy rzeczy, które mamy z własnych powodów, są u nich punktami sprzedażowymi:
**porównanie ze sprzężonym powiększeniem**, **klawiatura na pierwszym miejscu**
i **praca wyłącznie lokalnie, bez logowania i bez sieci**.

### Gdzie przebiega prawdziwa różnica

Nie w funkcjach, tylko w **jednostce pracy**. Oni obsługują wczorajszą sesję:
800 RAW-ów z jednego ślubu, z których trzeba wybrać 60 do obróbki, a potem
zapomnieć o narzędziu do następnego zlecenia. Tu jednostką jest **archiwum**
zbierane latami, do którego się wraca — 26 tysięcy zdjęć, z czego 20 605 nikt
nigdy nie otworzył.

Z tego wynika cała reszta: oni czytają kartę pamięci, my bibliotekę systemową;
oni kończą przekazaniem do edytora, my oceną, która zostaje, i kasowaniem.

Dwie rzeczy nie mają u nikogo odpowiednika. **Telefon** — żaden z nich nie
wychodzi poza komputer, a „przegląd w samolocie" to inny scenariusz niż stacja
w studiu. I **zbieranie tego, co system już policzył** zamiast liczenia
własnego: trzydzieści osiem wymiarów natychmiast, bez mielenia archiwum.

### Czego pilnować

**Cullibrate deklaruje obsługę Apple Photos**, a przy „ocenach ostrości" ma
„wkrótce". Czyli źródło mamy wspólne, a miarę, którą my już bierzemy z bazy
systemu, oni dopiero policzą sami. Gdyby kiedyś sięgnęli po `Photos.sqlite`,
przewaga by stopniała — ale musieliby przyjąć to samo, co my: Pełny dostęp do
dysku i dystrybucję poza sklepem.

### Co warto od nich wziąć

- **Survey, czyli porównanie więcej niż dwóch naraz.** Mamy dwa i turniej
  parami; trzy albo cztery kandydatury z wyborem jednej to realna luka.
- **Mapowanie klawiszy.** Przy naszym podejściu do ergonomii naturalne.
- **Odpowiedź na pytanie „i co dalej".** U nich to przekazanie do edytora;
  u nas kasowanie i gwiazdki w Zdjęciach. Może wystarczy — ale niech to będzie
  decyzja, a nie przeoczenie.

Czego **nie** brać: jasnego motywu w widokach ze zdjęciami. Powód się nie
zmienił, choć oni się nim chwalą.

## Zouti Photos — bliżej niż Cullibrate, wrzesień 2026

`zouti.app/photos` — macOS, wciąż w budowie, sklep + wersja próbna poza nim.
Warto zapisać osobno od Cullibrate, bo to nie jest wariant tej samej kategorii —
to ten sam pomysł źródłowy.

### Co jest wspólne, i to dosłownie

Czytają **wprost z baz biblioteki Zdjęć**, nie przez PhotoKit — „a purpose-made
engine that reads data directly from Photos… the real data, not a simplified
summary." To jest dokładnie nasze zdanie o `Photos.sqlite`, tylko po angielsku.

Pokazują **miary jakości jako histogram** — „plot quality and curation scores
as histograms or scatter plots and filter straight from the chart." To jest
nasz suwak nad histogramem, opisany od strony marketingu zamiast interakcji.
Nie skopiowali — trafili na te same kolumny i ten sam oczywisty sposób ich
pokazania. Dwie osoby czytające ten sam plik SQLite dochodzą do tego samego
wykresu.

Mają też **triage: Keep / Maybe / Reject, jeden klawisz, przejście dalej samo**
— nasza ocena gwiazdkowa plus filtr w innej postaci, i **piszą wyłącznie przez
oficjalne API Zdjęć**, nigdy do bazy — dokładnie nasza zasada z `PhotoLibrary`.

### Gdzie przebiega prawdziwa różnica

Oni budują **skrzynkę narzędziową dla ludzi, którzy chcą kontroli**: zagnieżdżone
grupy warunków all/any po dowolnym polu, edytor metadanych jak arkusz kalkulacyjny
z szablonami, eksport z szablonami nazw plików, AppleScript, serwer MCP dla
asystentów AI. To jest program dla kogoś, kto **wie, czego szuka**, i chce
zapytać bazę wprost.

My budujemy **jedno przejście przez archiwum**: siatka, filtr, ocena, kasowanie.
Nie ma tu query buildera i nie ma po co — cały wysiłek szedł w to, żeby nie
trzeba było umieć formułować warunku, tylko przesuwać suwak nad tym, co
faktycznie jest w bibliotece.

Dwie rzeczy nie mają u nich odpowiednika: **telefon** — Zouti jest wyłącznie
biurkowe — i **darmowość**. Oni brzmią jak narzędzie płatne, profesjonalne;
u nas cena nie pada, bo jej nie ma.

### Czego pilnować

**Dystrybucja przez Mac App Store, a czytanie wprost z bazy.** To są dwie rzeczy,
które u nas się wykluczały — sklep nie akceptuje aplikacji sięgających poza
piaskownicę, a `Photos.sqlite` wymaga Pełnego dostępu do dysku, którego sklep
nie rozdaje. Jeśli im się to uda, znaczy że jest droga, której nie znamy;
jeśli nie — ich „macOS 15.7+, sklep + wersja próbna" może się zmienić na coś
bliższego naszemu modelowi. Warto sprawdzić za parę miesięcy, jak faktycznie
wydali.

### Co warto od nich wziąć

- **Wykres punktowy obok histogramu** — dwie miary naraz, oś X i oś Y, zamiast
  jednej na raz. Przy trzydziestu ośmiu wymiarach realny sposób na pytanie
  „które zdjęcia są złe na dwa sposoby jednocześnie".
- **Wymuszone dociąganie oryginałów z iCloud** — pojedyncze zaznaczenie albo
  cała biblioteka na raz. Nie mamy tego wcale.

Czego **nie** brać: query buildera i edytora metadanych jako arkusza. To inny
produkt dla innego człowieka, i mieszanie tych dwóch pomysłów rozmyłoby oba.

## Wydanie poza sklepem ma inne prawa niż kompilacja u siebie

Pierwsza instalacja na cudzym Macu skończyła się odmową dostępu do biblioteki
zdjęć — bez pytania, bez wpisu na liście w Ustawieniach → Prywatność → Zdjęcia.
Wyglądało to na zepsuty system po aktualizacji i przez chwilę tak właśnie było
zdiagnozowane, błędnie. Zdjęcia działały; nie działała nasza aplikacja.

Przyczyna siedziała w różnicy między tym, co się kompiluje u siebie, a tym, co
się rozsyła. Wydanie ma włączony **hardened runtime**, bo bez niego nie przejdzie
notaryzacja. Hardened runtime odcina dostęp do zasobów osobistych, dopóki program
nie poprosi o nie **w podpisie**, uprawnieniem
`com.apple.security.personal-information.photos-library`. Klucz
`NSPhotoLibraryUsageDescription` w `Info.plist` to za mało: on mówi, co pokazać
w pytaniu, a nie wolno w ogóle pytać.

Odmowa jest przez to niema. `PHPhotoLibrary.requestAuthorization` wraca
z `.denied` natychmiast, pytanie się nie pojawia, a program nie trafia na listę
w Ustawieniach — bo z punktu widzenia systemu nigdy o nic nie poprosił.
`tccutil reset` nie pomaga, bo nie ma czego resetować.

Wniosek na przyszłość szerszy niż ten jeden klucz: **kompilacja deweloperska nie
jest próbą wydania**. Hardened runtime wyłączony, podpis inny, uprawnienia inne —
cała warstwa, która decyduje o dostępie do danych, jest u siebie nieaktywna.
Każda rzecz, o którą aplikacja prosi system, musi być sprawdzona na pakiecie
po notaryzacji, najlepiej na koncie, które nigdy jej nie widziało.

## Nie zapisuj w trakcie układania okna

Cztery osoby z zewnątrz zgłosiły, że program ginie przy pierwszym uruchomieniu.
Na maszynie deweloperskiej nie dało się tego powtórzyć ani razu. Trzy kolejne
poprawki chybiły, bo wszystkie zakładały wyścig i przesuwały rzeczy w czasie —
raz przez `Task`, raz przez `DispatchQueue.main.async`, raz przez odsunięcie
momentu, w którym podmienia się cały widok. Żadna nie pomogła nawet trochę,
i **to była najważniejsza wskazówka**: gdyby to był wyścig, choć jedna powinna
była zmienić częstotliwość. Skoro nie zmieniła żadna — to nie wyścig, tylko
pętla, która domknie się przy każdym starcie, o dowolnej porze.

Pętla siedziała w dwóch bindingach: widoczności panelu filtrów i widoczności
podglądu. Oba zapisywały wprost z settera do `@AppStorage`. Setter bindingu jest
jednak wołany przez SwiftUI **w trakcie przebiegu układu okna** — także wtedy,
gdy panelu nie zamyka człowiek, tylko system, bo panel przestał się mieścić.
Zapis unieważniał widok w środku jego własnego układu: kolumna zmieniała
szerokość, `setFrameSize:` rozsyłał powiadomienia, ktoś prosił o nowe
ograniczenia, prośba szła w górę do okna — a okno było w połowie poprzedniego
przeliczenia i rzucało wyjątkiem.

Dwie osobne pętle tłumaczą obserwację, która przez cały czas nie miała
wyjaśnienia: **ten sam wyjątek przychodził dwiema różnymi drogami** przez
`NSHostingView`, raz przez `didChangeValueForKey:`, raz przez
`invalidateSafeAreaInsets()`, przy niezmienionym kodzie w tamtym miejscu. Przy
wąskim oknie system zamyka raz jeden panel, raz drugi.

Dlaczego nigdy nie wyszło lokalnie: macOS pamięta ramkę okna osobno dla każdej
aplikacji, a `@AppStorage` trzyma preferencje. Maszyna, na której się pracuje,
ma jedno i drugie ustabilizowane od dawna, w szerokim oknie. Nic się nie
zamyka, więc nic się nie pętli. Świeża instalacja nie ma ani ramki, ani
preferencji — i suma minimalnych szerokości obu paneli (190 + 300 punktów,
zanim siatka dostanie pierwszy piksel) nie mieściła się w domyślnym oknie.

**Rozstrzygnęło dopiero obalanie, nie zgadywanie.** Zamiast wydać czwartą
poprawkę w ciemno, wystarczyło wyłączyć oba panele w preferencjach i uruchomić
**tę samą, niezmienioną wersję**:

```
defaults write pl.3210.lightbrary filters.sidebar -bool false
defaults write pl.3210.lightbrary preview.inspector -bool false
```

Crash zniknął. Jedna zmienna, żadnej nowej kompilacji, odpowiedź w trzydzieści
sekund. Przy błędzie, którego nie da się powtórzyć u siebie, test możliwy do
przeprowadzenia na cudzej maszynie jest wart więcej niż najlepsza hipoteza.

Zasada na przyszłość: **binding, którego setter zapisuje do trwałej pamięci,
musi odróżnić decyzję człowieka od decyzji systemu i nie zapisywać w trakcie
układu.** Trzy zabezpieczenia, w tej kolejności: nie zapisuj stanu, którego nie
kontrolujesz; nie zapisuj echa; zapisuj dopiero po zakończeniu układu.

### Sprostowanie: to nie było jeszcze to

Powyższe napisałem przekonany, że sprawa zamknięta. **Nie była.** Wersja
z rozerwanymi pętlami ginęła tak samo, a wyjątek przyszedł tym razem
z `updateConstraintsIfNeeded`, nie z `layoutIfNeeded`, i po raz pierwszy
z odsymbolizowanym śladem SwiftUI. Widać w nim, że to
`SplitViewChildController` dostaje zmianę minimalnego rozmiaru treści
w trakcie przeliczania ograniczeń — czyli sprzeczność o kolumnę, ale nie ta,
którą naprawiłem.

Rozstrzygnął dopiero wydruk `defaults read`. macOS zapisuje ramkę okna i stan
`NSSplitView` pod kluczem, w którego nazwie siedzi **pełny typ widoku
głównego**. Dodanie arkusza „sprawdź aktualizacje" zmieniło ten typ, więc
system uznał okno za nowe i nadał mu 1143×450 — za ciasne na układ. W takim
oknie `NSSplitView` zwinął panel filtrów i **zapisał to**, podczas gdy SwiftUI
niezależnie żądał, żeby panel był widoczny. Dwa niezgodne źródła prawdy o tej
samej kolumnie, unieważniające się nawzajem wewnątrz przebiegu ograniczeń okna.

To wyjaśniło też, dlaczego `defaultSize` nic nie dawało: **działa wyłącznie
wtedy, gdy zapisanej ramki nie ma.** A ona była.

Najgorsze było to, czego żadna poprawka w kodzie nie mogła naprawić sama
z siebie: **zły zapis przeżywa aktualizację.** Każdy, kto uruchomił dowolną
wcześniejszą wersję, miał go u siebie i dostawał tę samą awarię mimo poprawek —
czyli dokładnie czterej pierwsi testerzy, którzy ten błąd zgłosili. Stąd
jednorazowe skasowanie własnych kluczy okiennych przy starcie, sprawdzone
osobno: kasuje raz, zapisuje znacznik, przy drugim uruchomieniu nie rusza
zapamiętanego położenia.

Zasada, która z tego zostaje na trwałe, jest szersza niż bindingi:
**nazwa, pod którą system zapamiętuje stan okna, jest częścią typu widoku
głównego.** Zmiana hierarchii u samej góry — choćby dodanie jednego arkusza —
unieważnia zapamiętane położenie i daje oknu rozmiar, którego nikt nie
projektował. Przy oknie z kolumnami o twardych minimach to wystarczy, żeby
program przestał wstawać.

Przy okazji wyszedł drugi błąd, niezależny od awarii: zamknięcie panelu przez
system z braku miejsca zapisywało się jako wybór użytkownika. Wystarczyło raz
uruchomić program w wąskim oknie, żeby na zawsze zapamiętał „ten człowiek nie
chce podglądu".

### Trzecia droga: podmiana całej zawartości okna

Wrzesień 2026, tester z dużą biblioteką: 0.1.12 i 0.1.13 padały za każdym
razem, **zaraz po ekranie „Loading library…"**, z tym samym śladem
`SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)` w trakcie
`updateConstraintsIfNeeded`. Poprawka w 0.1.13 (odroczenie `Stepper`a
w `PairView`) była strzałem opartym na prawdopodobnym rozumowaniu i nie dała
nic — tester nigdy nie docierał do parowania. Wydana publicznie bez dowodu.

Przyczyna: `RootView.body` podmieniał **całą** zawartość okna — najpierw sam
`ProgressView`, po wczytaniu `NavigationSplitView` z inspektorem. Kontrolery
kolumn powstawały więc wewnątrz okna, które już żyje i jest w cyklu
wyświetlania. Przy małej bibliotece ekran ładowania ledwo mignie; przy dużej
kręciołek animuje się sekundami i sam napędza transakcje CoreAnimation, więc
podmiana trafia w środek przebiegu. Lokalnie nie dało się tego powtórzyć.

0.1.14: podział kolumn zamontowany od pierwszej klatki, ładowanie to stan
kolumny detalu (`screen(_:)` w `App.swift`). Build testowy sprawdzony u testera
**przed** publikacją — działa. Do tego `recordUncaughtExceptions()` zapisuje
`reason` wyjątku do `~/Library/Logs/lightbrary-exception.log`, bo systemowy
raport pokazuje sam stos, a przy wyjątkach AppKit-u tylko `reason` mówi, co się
gryzie.

Zasada: **struktura okna na najwyższym poziomie jest stała.** Stany (ładowanie,
brak dostępu) żyją wewnątrz, nie zamiast. Uwaga — ekrany `Permission`
(`.notDetermined`, odmowa) nadal podmieniają całe okno; przy pierwszym
uruchomieniu po nadaniu zgody to ta sama klasa zagrożenia, na razie bez
zgłoszeń.

## Zamrożone okno: ciężka praca na bazie poza głównym wątkiem

Start stał 6,8 s, synchronizacja 7,3 s bez przerwy (plus kilkanaście sekund
zacięć). Zgadywanie nie działało, więc najpierw pomiar: `Trace` pisze czasy
etapów i każde zacięcie głównego wątku powyżej 100 ms do logu systemowego
(`log show --last 5m --predicate 'subsystem == "pl.3210.lightbrary"'`).

Co wyszło i co zrobione:

- **Start.** Cechy czytane dwa razy (dwa `.task` przy pojawieniu się okna),
  po ~1,9 s każde, plus pobranie i przejście listy z Photos 1,4 s — wszystko
  na głównym wątku. Teraz raz, a `FeatureIndex.load` i `PhotoLibrary` liczą
  w tle i tylko podmieniają wynik. Start: 700 ms.
- **Synchronizacja.** Scalanie na głównym kontekście z oddechem co 500
  wierszy: kawałki rosły od 100 do 700 ms, bo kontekst z tysiącami
  niezapisanych zmian zwalnia każde zapytanie; zapis i budowa plików to
  kolejne 5 s ciągiem. Teraz sprzątanie, scalanie, zapis i pliki idą na
  **osobnym `ModelContext` w tle**; główny kontekst widzi wynik po zapisie.
  Na głównym zostaje tylko przeliczenie serii. Scalanie przypisuje cechy
  tylko przy różnicy — przepisanie tej samej wartości też brudzi rekord.
- **Pełny ekran.** Anulowane żądanie PhotoKit i tak woła handler (pusty
  obraz, bez flagi „zdegradowany"); przy skoku tam i z powrotem blokowało to
  szybki podgląd z dysku i zostawał spinner. `AssetImage` odrzuca odpowiedzi
  starych żądań.

Ryzyko do obserwacji: zapis synchronizacji w tle i ocena tego samego zdjęcia
w tej samej chwili mogą dać konflikt — przepada wtedy ten przebieg
synchronizacji (następny go powtórzy), nie ocena.

## Szybkie ocenianie: czego widok główny nie może obserwować

Po wyczyszczeniu kilkuset ocen okno stało minutami, a szybkie ocenianie
w pełnym ekranie szarpało po 0,5–1 s co kilka klawiszy. Pomiar w kolejności,
która zadziałała: `Trace` (etapy i `STALL` w logu) → `sample` w trakcie
(gdzie stoi wątek) → `Self._printChanges()` w ciałach głównych widoków,
z aplikacją uruchomioną przez `open --stdout plik` (uruchomiona wprost
z terminala dziedziczy jego brak zgody na Zdjęcia). Dopiero trzecie
pokazało przyczynę; próbki pokazywały tylko rozmyte „SwiftUI układa okno".

Zasady, które z tego wyszły:

- **Widok główny nie zależy od niczego, co zmienia się przy klawiszu.**
  Wskaźnik i zaznaczenie mieszkają w `Focus`, obserwowanym tylko przez
  widoki, które ich używają. `@State` w `RootView` zmieniane przy każdej
  ocenie (tak było z `focusID` i odłożonym zapisem) przebudowuje
  `NavigationSplitView`, pasek narzędzi i obie kolumny.
- **`@StateObject` obserwuje.** Obiekt, który widok tylko przekazuje dalej
  (`PerfMonitor`, `MetadataIndex`), trzymamy w `@State` — żyje tyle samo,
  ale nie budzi widoku przy każdej publikacji.
- **Zapis do `UserDefaults.standard` budzi każdy widok z `@AppStorage`.**
  Nic, co zmienia się przy ocenie, nie idzie do `UserDefaults` — stan
  odczytu z Photos (`NativeMemory`) ma własny plik.
- **`PHAsset.localIdentifier` nie jest polem** — składa napis z UUID przy
  każdym odczycie. W pętli po bibliotece czytamy zapamiętane identyfikatory
  (`Filters.cachedIDs`, `baseIDs`).
- **Właściwość obliczana czytana kilka razy na odrysowanie** liczy się
  kilka razy — `CullView.workingSet` ma pamięć na jeden obieg (`TurnMemo`).
- Przyciski w panelach obok oceniania mają `.focusable(false)`, a pełny
  ekran odzyskuje utracony fokus sam. Fokus nadal na moment znika na
  niektórych zdjęciach (np. z odczytanym tekstem) — przyczyna nieznana,
  skutek usunięty.

## isHidden nie nadaje się do cichej emisji — Apple pyta za każdym razem

Pomysł wyglądał dobrze na papierze: skoro `markedForDeletion` i tak jedzie
naszym plikiem wymiany, dorzućmy przy okazji `PHAsset.isHidden` — Apple
zsynchronizuje to sam przez iCloud, szybciej niż nasza ręczna synchronizacja,
za darmo. Ten sam wzorzec, który dobrze zadziałał dla `PHAssetChangeRequest
.rating` tego samego popołudnia.

Nie zadziałał. Pierwszy test na żywo: kliknięcie `X` w siatce wywołało
natywne okno „Allow 'lightbrary-mac' to hide this photo?" z przyciskami
Don't Allow / Hide. Drugie oznaczenie — to samo okno, jeszcze raz. Apple
traktuje ukrycie zdjęcia jak operację destrukcyjną, na równi z kasowaniem,
i wymaga potwierdzenia **przy każdym wywołaniu**, niezależnie od tego, że
aplikacja ma już pełny dostęp do biblioteki (`.readWrite`). To nie jest coś,
co dałoby się obejść entitlementem czy ustawieniem — to świadoma decyzja
systemu, żeby chronić użytkownika przed cichym znikaniem zdjęć.

Skutek w praktyce: każde `X` w trakcie oceniania przerywałoby klawiaturowe
przechodzenie przez archiwum oknem systemowym. Dla aplikacji, której cały
sens polega na szybkim tempie — dokładnie to samo zastrzeżenie, które
padło przy ocenach ("zapis przez PhotoKit jest o rzędy wielkości wolniejszy
od SwiftData i wywołanie go przy każdym swipie zabiłoby tempo") — tylko że
tu nie chodzi o szybkość, tylko o przerywnik wymagający kliknięcia.

Wycofane z gorącej ścieżki. `Review.markedForDeletion` zostaje jedynym
kanałem tej informacji — jedzie naszym plikiem wymiany, bez okna zgody.
*(Później zastąpione albumem „lightbrary – to delete" — dodanie do albumu
okazało się ciche; z pliku oznaczenia wypadły w schemacie 5.)*
Sama funkcja `PhotoLibrary.setHidden` zostaje w kodzie: mogłaby się przydać
jako jedna, świadoma, zbiorcza operacja przy rzadkiej, jawnej okazji (np.
w `DeletionReview`, gdzie i tak pyta się o zgodę na kasowanie) — tam jedno
okno na sto zdjęć jest do przyjęcia. Jedno okno na każde pojedyncze `X` nie
jest.

**Wniosek na przyszłość**: to, że coś jest dostępne przez `PHAssetChangeRequest`
i chronione tym samym `.readWrite`, nie znaczy, że zachowuje się tak samo po
cichu. `rating` — cicho. `isHidden` — głośno, za każdym razem. Nie da się
tego przewidzieć z dokumentacji ani z nagłówków SDK; trzeba to sprawdzić
na żywo, na jednym kliknięciu i na drugim, zanim się to podłączy wszędzie.

## Podział: eksporter poza sklepem, przeglądarki w sklepie

Wrzesień 2026. Rozwinięcie szkicu z „Dystrybucja: to nie wejdzie do App Store".
Ten rozdział jest zarazem **planem do wykonania** — pisany tak, żeby dało się go
przekazać wykonawcy bez tej rozmowy.

### Role

**Eksporter** — osobny program, open source na GitHubie, poza sklepem
(Developer ID + notaryzacja). Robi tylko to, czego PhotoKit nie da: czyta
`Photos.sqlite` i `psi.sqlite` (dziś cały `MetadataIndex.swift`) i zapisuje
plik z danymi wygenerowanymi. **Wyłącznie odczyt biblioteki** — to jego
argument: człowiek daje Pełny dostęp do dysku kodowi, który może przeczytać.
Żadnych ocen, albumów, kasowania.

**Przeglądarki** — iOS i macOS w sklepie, jeden rekord w App Store Connect
(ten sam `pl.3210.lightbrary`, zakup obejmuje obie platformy). **Kompletne bez
eksportera**: odciski liczy Vision na obrazach z PhotoKitu, więc serie i
parowanie działają zawsze. Dane z eksportera tylko dokładają.

iOS jest już w TestFlight z testerami zewnętrznymi, czyli przeszedł beta
review: dostęp do biblioteki, manifest prywatności, zapis `rating`, kasowanie.

### Trzy kanały

| Kanał | Co niesie | Kto pisze |
| --- | --- | --- |
| Photos (`PHAsset.rating`, album) | gwiazdki, oznaczenie do skasowania | przeglądarki; iCloud synchronizuje sam |
| Plik decyzji (per urządzenie) | dokładna waga, liczba ocen, stan serii, „wyzerowana ≠ nietknięta" | przeglądarka danego urządzenia |
| Pliki wygenerowane | odciski (per urządzenie), cechy + etykiety + słowa (eksporter) | producent; reszta tylko czyta |

Zasada: **co da się wyrazić natywnie, jedzie natywnie.** Bez wybranego folderu
wymiany przeglądarka i tak działa między urządzeniami — gwiazdki i oznaczenia
niesie Apple. Folder to opcja dla dokładnych wag, pojedynków i cech.

### Gwiazdka w Photos wygrywa przy zmianie

Waga (co 0,25) i gwiazdka Photos (całkowita) to ta sama decyzja w dwóch
rozdzielczościach. Zrobione w `NativeSync.swift`.

Pierwszy szkic mówił „przy niezgodności wygrywa gwiazdka". **Poprawione przed
wdrożeniem**, bo zniszczyłoby dane na dwa sposoby: oceny sprzed
`PHAsset.rating` nie mają gwiazdki w Photos, więc „brak gwiazdki wygrywa"
wyzerowałby archiwum; a nowsza waga przywieziona plikiem przegrywałaby ze
starą gwiazdką, której iCloud jeszcze nie zaktualizował.

Obowiązuje: **pamiętamy, co Photos pokazywał ostatnio, i działamy tylko na
różnicy.** Gwiazdka zmieniła się w Photos → waga idzie za nią (3,75 przy 4★
zostaje; niezgodna dostaje pełną wartość gwiazdki). Gwiazdka zdjęta w Photos →
„nieoceniona". Brak zmiany → nic. Pierwszy odczyt po instalacji to tylko punkt
odniesienia. Odczyt nie rusza `updatedAt` ani liczby ocen (`adoptNativeStars`,
jak `adoptFeatures`), a rekord założony z odczytu dostaje `.distantPast` —
inaczej wygrywałby przy scalaniu pliku z dokładniejszą wagą z drugiego
urządzenia.

**Własne zapisy nie mogą wracać jako „zmiana z zewnątrz".** Pierwsza wersja
rejestrowała zamiar zapisu w `Task`, chwilę po zmianie oceny w bazie; przy
szybkim `-` powiadomienie o poprzednim zapisie wpadało w tę lukę i podbijało
wagę z 3,25 do 4,0 — gwiazdka odbijała przy każdej granicy (z 4,5 do 1,0 trzeba
było 23 naciśnięć zamiast 14). Teraz `setRating` i `setMarkedForDeletion` są
synchroniczne: zamiar znany od razu, zapisy do Photos idą ściśle po kolei.
Sprawdzone na żywo; gwiazdki w systemowych Zdjęciach pojawiają się praktycznie
natychmiast.

Lista zdjęć nadąża za biblioteką przez `PHPhotoLibraryChangeObserver`:
przebudowa tylko przy zmianie zestawu, zmiany treści i albumu idą do odczytu
stanu natywnego. Ręcznie: ⌘R na Macu, pociągnięcie siatki na iOS.

### Oznaczenie do skasowania: album

Kasowanie pyta o zgodę **raz na wywołanie**, nie na zdjęcie — `DeletionReview`
kasuje całą pulę jednym `performChanges`. Oznaczenie jedzie albumem
**„lightbrary – to delete"** (`PhotoLibrary.setMarkedForDeletion`): sprawdzone
na macOS 27 — dwa zdjęcia pod rząd **bez okna zgody**, trafiły do albumu.

Odczyt w drugą stronę zrobiony tą samą regułą co gwiazdki: zdjęcie weszło do
albumu → oznaczone, wyszło → odznaczone (także gdy wyjęte ręcznie
w systemowych Zdjęciach). Sprawdzone na Macu i telefonie: kosz pojawia się
na drugim urządzeniu bez pliku wymiany. `markedForDeletion` nadal jedzie też
plikiem — wypadnie z pliku decyzji przy jego podziale (krok 3). Album szukamy
**po nazwie** — `localIdentifier` albumu jest inny na każdym urządzeniu.

**Serie z aparatu (burst) kasują się w całości.** Biblioteka wczytuje je tak,
jak PhotoKit robi to domyślnie — jako jedno zdjęcie, reprezentanta — a skasowanie
reprezentanta zabiera wszystkie klatki. Wyszło na żywo: okno kasowania mówiło
„To delete: 1", system pytał „Delete 10 photos from this burst?". Teraz okno
liczy klatki (`PhotoLibrary.deletionSize`), pokazuje je na kafelku i przycisku,
a miniatura serii w siatce ma plakietkę. Sprawdzone też w drugą stronę: po
„Keep Only Selection" w Zdjęciach stary reprezentant wypada z albumu i lightbrary
samo zdejmuje oznaczenie.

**Temat na później:** lightbrary w ogóle nie pokazuje pojedynczych klatek serii,
choć to dokładnie materiał dla parowania. Dziś wybór klatek robi się w Zdjęciach
(„Make a Selection…" na Macu, „Select…" na iPhonie).

Obejście okna zgody przy kasowaniu nie wchodzi w grę: to świadome
zabezpieczenie systemu, a każda droga dookoła (skrypt, `Photos.sqlite`,
klikanie okna) albo nie działa w piaskownicy, albo nie przejdzie review, albo
psuje bibliotekę.

### Pliki wymiany: wygenerowane osobno od decyzji

*Sprostowanie: pierwsza wersja tego akapitu mówiła o jednym pliku 59 MB
przepisywanym przy każdej ocenie. Nieprawda — od 19 września (`db70610`) były
już dwa pliki na urządzenie: `-ratings` (oceny, werdykty i cechy) i
`-fingerprints` (przepisywany tylko przy zmianie liczby odcisków).*

**Zrobione (schemat 5):** trzy pliki na urządzenie, każdy z jednym piszącym —
`-ratings` (same decyzje: waga, oceniono, liczba ocen, `updatedAt`, werdykty),
`-fingerprints` (bez zmian) i nowy `-features` (cechy; pisze go tylko Mac, który
sam je wczytał z baz, i tylko po nowym wczytaniu). Oznaczenia do skasowania
wypadły z pliku całkowicie — jadą tylko albumem. Plik niesie `minReader`,
kolumny czytane po nazwie; sprawdzone na plikach zbudowanych ręcznie: stary
schemat 4 czytany (cechy wyjęte z tabeli ocen), plik „z przyszłości" z nieznanymi
kolumnami i tabelą czytany, `minReader` wyższy od czytnika i schemat 2 odrzucone.

Podział **wg tego, czy da się odtworzyć**:

- **wygenerowane** — utrata obojętna, brak scalania, nowsza wersja zastępuje
  całość, przepisywane rzadko;
- **decyzje** — nie do odtworzenia, scalanie per rekord jak dziś, małe,
  przepisywane często; warto trzymać z historią wersji.

Zysk ponad rozmiar: znika reguła „kto ma, ten daje" (cechy w `Review` omijające
straż czasu, żeby pusty pomiar nie skasował oceny). W osobnych plikach ten błąd
jest niemożliwy z konstrukcji.

Warunki:
- **Klucze stabilne.** Decyzje wskazują zdjęcia identyfikatorem chmurowym, a serie
  składem grupy — nigdy wierszem pliku wygenerowanego. Inaczej przeliczenie
  odcisków unieważnia pracę człowieka.
- **Zgodność w przód.** `SyncFile.readable = 3...4` dziś odrzuca plik z nowszym
  schematem w całości. Po podziale piszą go programy wydawane osobno — stara
  przeglądarka ze sklepu nie może oślepnąć, gdy eksporter podbije schemat.
  Każdy plik: własny numer schematu, wyższy akceptowany, nieznane kolumny
  ignorowane.

Etykiety i słowa do wyszukiwania w pliku eksportera — **postanowione: tak,
przycięte** (OCR do unikalnych słów na zdjęcie). Dochodzą w kroku 4 jako nowe
kolumny tabeli `feature`, bez podbijania `minReader`. Sklepowy Mac zachowuje
panel metadanych i wyszukiwanie, iOS dostaje wyszukiwanie, którego sam nie
zbuduje.

**Eksporter — pierwsza połowa zrobiona** (`Sources/Exporter`, trzeci target
w tym samym repozytorium, nie osobnym: `SyncFile` to kontrakt między programami
i jedna kopia źródła zamiast dwóch). Pasek menu, bez Docka; eksport przy starcie
(gdy ostatni starszy niż godzina) i 5 minut po ostatniej zmianie w bibliotece;
plik `-features` pod własną nazwą urządzenia, nieprzepisywany przy tej samej
treści. Etykiety i słowa — druga połowa. Czytnik baz wydzielony do
`MetadataStore.swift`, wspólnego z przeglądarką.

**macOS 27 wymienił indeks wyszukiwania: `psi.sqlite` zniknął, jest
`leo.sqlite`.** Wyszło przy eksporcie słów — kolumna była pusta dla wszystkich
25 012 zdjęć. Skutek uboczny, niezauważony od aktualizacji systemu: na Macu nie
działało wyszukiwanie (ciche „Nothing matches" na wszystko) ani połowa panelu
metadanych (osoby, miejsca, sceny, tekst). `Photos.sqlite` bez zmian — cechy,
miary i EXIF czytały się dalej.

Układ `leo.sqlite`, ustalony na żywej bibliotece: `items` (zdjęcie: `type = 1`,
`identifier` = UUID, `lexeme_ids` = lista 4-bajtowych numerów haseł little-endian)
i `lexicon` (numer hasła, kategoria, treść; jedno hasło = wiele synonimów, pierwszy
wiersz to forma podstawowa). Kategorie: 1xxx czas i święta, 2xxx miejsca (od lokalu
2220 po kraj 2160), 3000 osoby, 3010 zwierzęta (z ogólnikami „Person", „My Puppy"),
4000 sceny, 4010 gatunki, 4020 zabytki, 4090/4100 wydarzenia i wycieczki, 4120 OCR,
6000 aparat, 7xxx albumy i wspomnienia, 8xxx techniczne, 11000 typ dokumentu,
**11010 nazwiska odczytane z dokumentów tożsamości — nie eksportujemy.** Czytnik:
`MetadataStore.leoTerms` (słowa dla całej biblioteki, 0,4 s na 25 tys. zdjęć),
`leoSearch`, `readLeoIndex` (panel). Stary `psi.sqlite` dalej obsługiwany, gdyby
ktoś został na starszym systemie.

**Spostrzeżenie sprzeczne z wcześniejszym ustaleniem** (wyżej: „zgoda na
bibliotekę dotyczy PhotoKit, nie plików"): eksporter uruchomiony z Findera,
z samą zgodą na Zdjęcia i **bez** Pełnego dostępu do dysku, przeczytał bazy
i wyeksportował 25 012 zdjęć (macOS 27, Mac Radka). Jeden test, jedna maszyna —
do potwierdzenia na drugim Macu, zanim przestaniemy mówić ludziom o Pełnym
dostępie. Przycisk do ustawień w eksporterze zostaje jako zapas.

Eksporter — **postanowione**: mała aplikacja w pasku menu (Pełny dostęp do dysku
nadaje się aplikacji, nie Terminalowi), działająca sama: obserwuje bibliotekę
i eksportuje po uspokojeniu się zmian. W pasku: data ostatniego eksportu
i ręczne uruchomienie. Pełne wydanie w App Store dopiero po rozdzieleniu na trzy
programy; do tego czasu iOS w TestFlight.

Przeglądarka pokazuje **wiek danych z eksportera** — to migawka.

**Synchronizacja automatyczna** (zrobione): daty cudzych plików sprawdzane przy
powrocie aplikacji na wierzch i co dwie minuty — z metadanych, bez pobierania;
czytane tylko pliki zmienione od ostatniego odczytu. Własny plik decyzji zapisuje
się 20 s po ostatniej zmianie w bazie. Odcisków i cech tryb automatyczny nie
odsyła (przyrost z cudzego pliku przepisałby nasze 50 MB), ręczne „sync now"
dalej czyta i pisze wszystko. Przeciw pętli: zapis bazy tylko przy zmianach
i plik decyzji pomijany, gdy jego treść (skrót, niezależny od kolejności) się
nie zmieniła — inaczej dwa urządzenia przerzucałyby się tym samym plikiem bez
końca. Znany koszt: zmienione odciski Maca (~50 MB) pobiorą się na telefonie
same, także przez sieć komórkową.

### Piaskownica i sklep na Macu

- Uprawnienia: `app-sandbox`, folder wybrany przez użytkownika (zapis), zakładki
  (`bookmarks.app-scope`). Na review: jedno zdanie uzasadnienia na każde.
- **Migracja kontenera** przy pierwszym uruchomieniu w piaskownicy: magazyn
  SwiftData, `UserDefaults`, zakładka do folderu. Bez planu testerzy zaczynają
  od zera (patrz „Zakładka do folderu przestaje obowiązywać…").
- Z wersji sklepowej wypada `UpdateCheck` i `wersja.json`.
- Kolejność: TestFlight na Macu z testerami zewnętrznymi, potem pełne review.
  Wersja Developer ID tylko na czas przejścia, do pierwszego zatwierdzenia.
- Pierwsze wydanie w sklepie **bez wzmianki o eksporterze** — aplikacja nie
  może wyglądać na niekompletną bez zewnętrznego programu. Link w kolejnej
  wersji.
- Nigdzie słowa „beta" — sklep tego nie przyjmuje; od tego jest TestFlight.

### Interfejs: oznaczone widać na miniaturze

`Thumbnail` (`GridView.swift`) dostaje `isMarkedForDeletion`. Czerwone
`trash.fill` w **prawym górnym rogu** (lewy górny: podpis filtru, dół: gwiazdki),
w tej samej kapsułce co gwiazdki, plus lekkie przygaszenie zdjęcia — żeby
oznaczone było widać przy szybkim przewijaniu. `tile(_:)` ma już `Review`.
Pasek miniatur w `CullView` używa tego samego kafelka.

### Kolejność kroków

1. ~~Ikona kosza na miniaturach.~~ Zrobione.
2. ~~Odczyt gwiazdki i albumu z powrotem.~~ Zrobione, z regułą „wygrywa przy
   zmianie" (wyżej).
3. ~~Format: podział pliku na wygenerowane i decyzje, zgodność w przód.~~
   Zrobione, schemat 5.
4. Wydzielenie eksportera (`MetadataIndex` + zapis pliku wygenerowanego) do
   osobnego repozytorium.
5. Przeglądarka macOS w piaskownicy + migracja kontenera.
6. TestFlight na Macu, potem review.

### Reguły dla wykonawcy

- Nic na stronę, do TestFlightu ani `git push` bez potwierdzenia Radka.
- Akcje destrukcyjne na bibliotece tylko na zdjęciach testowych.
- Komentarze odróżniają hipotezę od faktu.
- Punkty kontrolne z przeglądem, bo błąd kosztuje dane albo zaufanie
  testerów: **migracja kontenera** (test na kopii danych), **format plików**
  (kontrakt między programami, trudny do odkręcenia), **wszystko, co dotyka
  układu okna na Macu** (ta klasa awarii nie odtwarza się lokalnie — patrz
  „Nie zapisuj w trakcie układania okna").

## Co czeka

### Strona a recenzja w sklepie

Recenzent wchodzi na lightbrary.app przez adresy z App Store Connect (dziś
tylko /privacy, przy zgłoszeniu dojdzie /support), a stopka prowadzi dalej —
do /manual i /download. Instrukcja (`/manual`, od 25 września 2026) zastąpiła
/sync, które przekierowuje na `/manual#sync`. Źródła stron leżą tylko na
serwerze; kopie sprzed zmian w `/var/backups/lightbrary-2026-09-25/`.

**Przed zgłoszeniem iOS:**
- adres wsparcia w App Store Connect: `https://lightbrary.app/support`;
- zdjąć ze stron „TestFlight" i „This is a beta" (instrukcja, pobieranie).

**Przed zgłoszeniem Maca do sklepu:**
- przepisać w instrukcji wszystko o Pełnym dostępie do dysku i czytaniu baz
  biblioteki tak, żeby dotyczyło **tylko eksportera**. Wersja ze sklepu działa
  w piaskownicy na publicznych API; strona mówiąca, że aplikacja czyta prywatne
  bazy Photos, to dla recenzenta czerwona flaga (wytyczna 2.5.1). Dotyczy
  sekcji Setting up, Filters (load measures, search) i If something looks off.

### Przesunięcie zakresu: z sortownika w przeglądarkę

Odkrycie, ile gotowych danych leży pod biblioteką, zmienia klasę narzędzia.
Sortownik potrzebował jednego dobrego widoku. Przeglądarka potrzebuje sposobu
na **przecinanie zbioru** i wracanie do tego samego miejsca z różnych stron.

Kształt docelowy, ustalony po pierwszym użyciu zakładki cech — **zrobiony**,
opis w rozdziale „Jeden zbiór roboczy":

- **Siatka jako tryb główny** — nie jedna z czterech zakładek.
- **Pojedynczy podgląd** jako drugi tryb.
- **Cechy jako osie** siatki i podglądu — sortowanie i filtrowanie, nie osobny
  ekran. Zakładka była najszybszym sposobem sprawdzenia, czy sygnał jest
  cokolwiek wart; nie jest trybem, tylko kryterium, tak samo jak rok.
- **Ocenianie i turniej schodzą do roli dodatku** — wywoływanego z przeglądarki,
  gdy już się coś znalazło.

Czego dziś brakuje do poziomu Bridge'a: zaznaczania i operacji na grupie,
swobodnego porównywania obok siebie, grupowania po dniu, serii albo osobie — choć system ma policzone
momenty i 7 290 klastrów osób.

Przed kodowaniem: **poużywać**. Pierwsza obserwacja z używania jest taka, że
zbiór zrzutów ekranu z `ZISDETECTEDSCREENSHOT` bije album „Zrzuty ekranu"
w Zdjęciach — Apple idzie po typie pliku, a to jest wynik rozpoznania, więc
łapie też sfotografowany ekran i obrazek zapisany z sieci. Ten sam silnik, dwa
różne pytania, i użytkownikowi wystawiono gorsze. Takich miejsc jest tam
zapewne więcej.

- **Metadane w pojedynku** — przy dwóch podobnych klatkach ISO i czas
  rozstrzygają szybciej niż oko.
- **Konwersja do HEIC przed importem** — osobne narzędzie, opisane wyżej.
- **Sprawdzić `PHAssetResourceManager`** — być może strumieniuje dane
  zasobu bez oznaczania zdjęcia jako lokalnie dostępnego. Gdyby tak było,
  podgląd 1:1 na telefonie przestałby zajmować miejsce na stałe. To się
  sprawdza pomiarem wolnego miejsca przed i po, na dziesięciu zdjęciach.

Zdjęte z listy: **archiwum 0,5–1 TB poza Photos**. Radek uporządkował je
sam, a dla innych użytkowników właściwą odpowiedzią jest narzędzie do
przygotowania zbioru przed przeprowadzką, nie drugie źródło w katalogu.
- **Synchronizacja odcisków i stanu serii** — dziś każde urządzenie liczy
  osobno i nie widzi rozstrzygnięć drugiego.
- **Pasek narzędzi na macOS** — „policz odciski" ucina się do „p…".
- **Archiwum 0,5–1 TB poza Photos** — katalog musi traktować bibliotekę jako
  jedno ze źródeł, nie jako fundament.

## Ograniczenia darmowego konta

Podpis wygasa po **7 dniach** — potem `./install.sh ios`. Bez CloudKit, bez
powiadomień. Team ID w `Local.xcconfig`, poza repozytorium.
