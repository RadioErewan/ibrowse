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

## Co czeka

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
