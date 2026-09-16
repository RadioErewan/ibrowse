# lightbrary — brief projektowy

Dokument dla kogoś, kto ma projektować interfejs tej aplikacji. Opisuje, co
aplikacja robi, dla kogo, co jest już rozstrzygnięte i dlaczego, oraz gdzie
naprawdę potrzeba pomocy.

> **Wersja druga.** Zmiany wobec pierwszej: aplikacja nazywa się teraz
> **lightbrary** (było `ibrowse`); pytanie o rozkład okna z §9 **ma odpowiedź**
> i sekcja to odnotowuje; sekcja cech przestaje być listą pięciu pozycji i staje
> się **listą otwartą, sondowaną w bazie** — powód i pomiary w §6.

---

## 1. Czym to jest

**Narzędzie do wielokrotnego przeglądania własnego archiwum zdjęć**: szukania,
oceniania, porównywania i usuwania. Nie katalog, nie tagger, nie edytor.

Pracuje na bibliotece systemowych Zdjęć Apple i czyta z niej także to, czego
sama aplikacja Zdjęcia nie pokazuje: policzone przez system miary ostrości,
naświetlenia, wykryte twarze i zamknięte oczy, rozpoznane zrzuty ekranu.

macOS i iOS. Wszystko lokalnie — nic nie opuszcza urządzeń, nie ma konta, nie
ma serwera.

## 2. Dla kogo

Fotograf z archiwum rzędu **kilkudziesięciu tysięcy zdjęć**, zbieranym
kilkanaście lat. Zna narzędzia tej klasy — Adobe Bridge, Lightroom,
Capture One — i porównuje do nich.

To nie jest odbiorca, któremu wystarczy, że się da. Drobiazgi obsługi są tu
treścią, a nie wykończeniem: opór gestu, to czy kadr dojeżdża do końca, czy
licznik skacze przy przewijaniu. Projekt, który działa, ale jest o pół kroku
za wolny albo o jedno kliknięcie za długi, zostanie odrzucony.

### Sytuacje użycia, na które to jest projektowane

- **Wieczorna sesja przy dużym ekranie.** Godzina albo dwie, przegląd jednego
  roku, ocenianie z klawiatury.
- **Samolot i kanapa.** Telefon albo iPad, bez sieci, kciukiem. Przegląd
  zrzutów ekranu do skasowania, albo zdjęć z zamkniętymi oczami.
- **Powrót po tygodniu.** Praca ma się odnajdywać sama — bez pytania
  „gdzie ja skończyłem".

Założenie leżące pod wszystkim: **praca rozłożona na lata i wiele podejść**,
nie na jedno posiedzenie. Archiwum, przez które nikt nigdy nie przejdzie, to
nie archiwum, tylko kopia zapasowa czegoś, co przestało istnieć.

## 3. Rozstrzygnięcia, które wiążą

Te rzeczy zostały już przemyślane i mają uzasadnienie. Można je podważać, ale
trzeba wiedzieć, w co się uderza.

**Zawsze ciemno, nigdy za systemem.** Jasne otoczenie sprawia, że zdjęcie
wydaje się ciemniejsze i mniej kontrastowe, niż jest. Narzędzie do oceniania
zdjęć w jasnym interfejsie kłamie o materiale, na podstawie którego
podejmuje się decyzje. Lightroom, Bridge i Capture One są ciemne z tego
samego powodu.

**Interfejs po polsku**, małą literą, bez wielkich liter w etykietach
przycisków. Brzmienie jest rzeczowe i oszczędne: „oznacz do usunięcia",
nie „Usuń zaznaczone elementy".

**Wygląd natywny, nie własny.** Wszystkie próby rysowania własnych pasków
i przegród były cofane — własny pasek pod tytułem czytało się jako wzorzec
z Windows. Używamy prawdziwego toolbara, prawdziwego paska bocznego,
prawdziwego inspektora.

**Ocena jest jedną liczbą ciągłą 0–5.** Gwiazdki to tylko jej widok. Nie ma
flag, kolorów ani etykiet — jedna skala i koniec. Usuwanie nie jest osobnym
narzędziem: wypycha się zdjęcie w dół skali, a potem filtruje i kasuje hurtem.

**Zdjęcie dostaje tyle ekranu, ile się da.** Wszystko inne chowa się, znika,
albo pojawia tylko wtedy, gdy ma coś do powiedzenia.

## 4. Architektura: jeden zbiór roboczy

To jest najważniejsze pojęcie w aplikacji i wszystko się wokół niego kręci.

**Filtr wycina zbiór. Kolejność go porządkuje. Każdy tryb widzi ten sam zbiór
w tej samej kolejności.** Kliknięcie w kafelek w siatce wchodzi w ocenianie
dokładnie tego zdjęcia, a „następne" znaczy to samo w obu miejscach.

Było kiedyś inaczej — zestawienia cech miały własny zbiór — i to był błąd,
który psuł nawigację w sposób niemożliwy do obejścia. Projekt nie może do tego
wrócić: **nie wolno wprowadzać drugiej listy zdjęć obok tej głównej.**

Z tego wynika też podział pojęć:

| pojęcie | znaczenie |
|---|---|
| **warunek** | co wchodzi do zbioru (rok, ocena, cecha, tekst) |
| **kolejność** | co znaczy „następne zdjęcie" |
| **tryb** | co robię z tym, co widzę (oglądam / oceniam / porównuję) |

Tryby to **narzędzia**, nie widoki. Nie wolno robić trybu z pytania o zbiór.

## 5. Ekrany

### Filtr

Na macOS **pasek boczny na stałe** przy lewej krawędzi okna (190–340 pt,
domyślnie 230). Na iOS arkusz wywoływany przyciskiem.

Filtr jest widokiem, nie czynnością. Powodem są liczniki: **każdy warunek
niesie własną liczbę** i mówi, ile dałby, zanim się go wybierze. Dopóki panel
trzeba było otworzyć, nie dało się tego wiedzieć bez przerywania pracy.

Sekcje, w kolejności:

1. **Szukaj w treści** — pole tekstowe. Szuka po etykietach scen, imionach
   osób, nazwach miejsc i tekście odczytanym ze zdjęć. Tylko macOS; na
   telefonie mówi wprost, że indeksu tam nie ma.
2. **Ocena** — cztery wiersze z licznikami: wszystkie / nieocenione /
   ocenione / do usunięcia. Pod nimi, gdy wybrane „ocenione", skala gwiazdek.
3. **Cechy systemu** — **lista otwarta**, nie zamknięty zestaw. Dziś zapięte
   są cztery miary (poruszone, źle naświetlone, zamknięte oczy, zrzuty ekranu)
   plus „bez warunku", ale dostępnych jest ich około trzydziestu i będzie
   przybywać. Na wierzchu stoją najczęściej używane, reszta pod roletą.
   Szczegóły i pomiary w §6 — to jest najważniejsza część tego briefu.
   Przy miarach ciągłych pojawia się suwak progu.
4. **Kolejność** — sześć wierszy bez liczników: jak w bibliotece / od
   poruszonych / od niedoświetlonych / od zamkniętych oczu / od najlepszych /
   od najgorszych.
5. **Zakres lat** — dwa menu, „od" i „do", z liczbą zdjęć przy każdym roku.

Na dole stopka: **Pasuje 208 z 25 191** i przycisk „wyczyść".

**Skala gwiazdek jest zbiorem przełączników, nie zakresem.** Sześć pozycji
(0–5, zero z przekreśloną gwiazdką), każda zapalana niezależnie, każda z liczbą
zdjęć pod spodem. Można zapalić samą trójkę albo trójkę i piątkę z pominięciem
czwórki. Pusty zbiór znaczy „bez zawężania", nie „nic".

### Siatka

Jedyny widok kafelków w aplikacji. Kafelki adaptacyjne, 3 pt odstępu, bez
paddingu, bez podpisów pod spodem — ma to być ściana obrazków.

Na kafelku trzy nakładki:

- **plakietka miary** w lewym górnym rogu (np. `0,31`, `3 z 4`, `zrzut`) —
  pojawia się tylko wtedy, gdy w grze jest cecha, i tłumaczy, dlaczego zdjęcie
  stoi w tym miejscu;
- **gwiazdki** u dołu, gdy zdjęcie jest ocenione;
- **żółta ramka** na zdjęciu, na którym stoi praca.

Na macOS nad siatką pasek z suwakiem rozmiaru kafelka (80–280 pt) i licznikami
wydajności. Na iOS kafelek jest stały (92 pt, cztery kolumny w kciuku) i paska
nie ma — zabierałby jedną trzecią ekranu.

**Pasek operacji na grupie** pojawia się tylko przy założonym filtrze:
liczba zdjęć w zbiorze i przycisk „oznacz do usunięcia", a po oznaczeniu
czerwone wyjście do przeglądu.

### Ocenianie

Jedno zdjęcie na całym ekranie, czarne tło.

**Na Macu klawiatura:** `1`–`5` ocena, `−`/`+` przesunięcie o ćwierć punktu,
`←`/`→` nawigacja, `spacja` dalej, `X` oznacz do usunięcia, `Z` podgląd 1:1,
`I` metadane, `T` pasek miniatur.

**Na telefonie gest:** w bok przewijanie (obraz idzie za palcem, próg 50 pt,
odbicie przy geście wycofanym), w pionie ocena — w górę lepsze, w dół gorsze.
Sąsiednie zdjęcia widać podczas przewijania jako miniatury; czarne pole na
krańcu zbioru mówi, że dalej nic nie ma.

Pod zdjęciem **pasek miniatur** — widoczna kolejka. Pokazuje ten sam zbiór
w tej samej kolejności, bieżące zdjęcie na środku, z plakietkami miary.
Pozwala skoczyć dalej niż o jedno zdjęcie bez wychodzenia do siatki. Chowa się.

Stopka: gwiazdki (klikalne), znacznik „do usunięcia", podpowiedź klawiszy,
licznik pozycji `1447 / 25 191`.

**Metadane** — na macOS natywny inspektor przy prawej krawędzi, na telefonie
arkusz na żądanie. Zawiera technikę zdjęcia (aparat, obiektyw, czas, przysłona,
ISO, lampa, wymiary) i to, co widzi system: osoby, zwierzęta, okoliczność,
etykiety scen.

**Podgląd 1:1** — osobne okno, czarne, jeden piksel zdjęcia na jeden piksel
ekranu, przesuwane przeciąganiem. Jedyne miejsce z prawdziwymi pikselami, bo
tylko tam da się ocenić ostrość. Na Macu otwiera się w punkcie, w którym stał
kursor.

### Parowanie

Odpowiedź na „mam trzy podobne kadry, nie chcę wybierać, który zostaje".

System wykrywa serie podobnych zdjęć i puszcza je przez turniej „które z tych
dwóch jest lepsze". Dwa zdjęcia obok siebie, jedna decyzja, zwycięzca zostaje
i mierzy się z następnym. Seria z N zdjęć kosztuje N−1 decyzji.

Wynik zależy od tego, **kogo się pokonało**, nie od samego zwycięstwa. Widok
zawsze podaje pierwszą nierozstrzygniętą serię, więc nie ma indeksu do
zapamiętywania.

### Pasek stanu

Na dole okna, tylko na macOS i **tylko wtedy, gdy coś trwa**: liczenie odcisków
wizualnych, synchronizacja, zapis do albumów. Znika bez śladu, gdy nie ma
o czym mówić. Nazwa etapu jest tam ważniejsza od paska postępu — przy pobieraniu
50 MB jedyne pytanie brzmi „czy to jeszcze działa".

### Synchronizacja

Między urządzeniami przez plik w folderze, który użytkownik sam wskazuje
(zwykle iCloud Drive). Każde urządzenie pisze własny plik i czyta cudze.
Ręczna po obu stronach — świadomie, ale to jest miejsce z problemem
ergonomicznym: po powrocie z podróży trzeba pamiętać o kliknięciu na drugim
urządzeniu, a dopóki się nie kliknie, wygląda to jak utrata pracy.

## 6. Cechy systemu: lista otwarta, nie zestaw

To jest część briefu, która zmieniła się najmocniej, i najważniejsza dla
projektu panelu filtru.

### Dlaczego otwarta

Bo **nie wiemy, ile da się z tej biblioteki wyciągnąć**, a ponadstandardowe
przekroje przez archiwum są tym, po co ta aplikacja istnieje. Zamknięcie sekcji
do czterech pozycji zabiłoby dokładnie to, co jest w niej najciekawsze.

Do tego w schemacie bazy leżą wymiary **kiedyś zaimplementowane i porzucone**
oraz takie, **które system dopiero zacznie wypełniać**. Zestaw dostępnych miar
zmienia się więc z każdą wersją systemu operacyjnego, bez naszego udziału.

### Ile ich naprawdę jest

Zmierzone na archiwum 26 123 zdjęć. Poniżej skrót; pełne liczby są
w `DECYZJE.md`.

**Miary ciągłe** — nadają się na sortowanie i na próg. Kuracja, estetyka
ogólna, widoczność we wspomnieniach, ikoniczność, aktywność w kadrze,
symetria, immersyjność, wzory, ostrość tematu, przydatność na tapetę,
kompozycja, oświetlenie, ciekawy temat, żywe kolory, harmonia kolorów, ładne
rozmycie tła, dobrze wybrany temat, dobre skadrowanie, dobry moment ujęcia,
perspektywa, odbicia, obróbka, przechył kadru, szum, nieudane ujęcie, natrętny
obiekt w kadrze. Do tego trzy już używane: poruszenie, naświetlenie, słabe
światło.

**Warunki dwustanowe** — nadają się na wiersz z licznikiem: nigdy nieoglądane
(20 605 zdjęć), ma lokalizację, osoby w kadrze, twarze w kadrze, obejrzane choć
raz, zrzuty ekranu, HDR, portret z mapą głębi, wideo, kiedyś udostępnione,
seria aparatu, ulubione, duplikat wskazany przez system.

Czyli **około trzydziestu**, a nie cztery. Prawie wszystkie wypełnione dla
całej biblioteki.

### Pułapka, na którą trzeba uważać przy projektowaniu warunków

Te kolumny nie mają wspólnej konwencji i **nie da się jej odgadnąć**:

- część jest w zakresie 0–1, wyżej znaczy lepiej;
- część jest symetryczna, −1 do 1;
- ikoniczność ma zakres −2 do 1;
- szum, nieudane ujęcie i natrętny obiekt **mają wyłącznie wartości ujemne**,
  gdzie **zero jest wynikiem najlepszym**;
- dwie kolumny używają −1 jako znacznika „nie dotyczy";
- jedna kolumna nazywa się `BLURRINESSSCORE`, a rośnie wraz z **ostrością** —
  nazwa znaczy odwrotność tego, co mierzy.

Praktyczny wniosek dla interfejsu: **suwak progu nie może mieć sztywnego
zakresu 0–1**. Dla miary o zakresie −0,217 do 0,076 taki suwak nie znaczy nic.
Granice muszą pochodzić z rzeczywistego rozkładu, mierzonego przy każdym
wczytaniu cech.

### Co aplikacja robi sama, a co jest opisane ręcznie

**Sama, przy każdym wczytaniu:** sprawdza, które kolumny istnieją w tej wersji
systemu, ile mają wartości, jaki mają rozkład, i czy w ogóle niosą sygnał.
Kolumna o jednej wartości w całym archiwum nie jest przekrojem.

**Ręcznie, raz:** nazwa po ludzku, kierunek (czy wyżej znaczy lepiej), co
znaczy zero. Tego nie da się odkryć — patrz `BLURRINESSSCORE` wyżej.

Skutek dla projektu: aplikacja może **odkryć nową miarę** po aktualizacji
systemu i o niej powiedzieć. Warto przewidzieć, jak to zakomunikować.

### Trzy powody, dla których miara może być pusta

Wyglądają identycznie, a znaczą co innego i wymagają innego zachowania:

1. **wymiar porzucony** — kolumna została po funkcji, której już nie ma;
2. **wymiar jeszcze niewdrożony** — kolumna jest, system jej nie wypełnia;
3. **pusta w tej bibliotece** — miara działa, tylko ten użytkownik nie ma
   takich zdjęć.

Pierwsze dwa mają **zniknąć z listy**. Trzeci ma **zostać z licznikiem zero**,
bo brak wyników jest informacją. Rozróżnienia nie da się zmierzyć, więc spis
dzieli miary na **rdzenne** (pokazywane zawsze) i **znalezione** (pokazywane,
gdy niosą sygnał).

### Co ma być na wierzchu, a co pod roletą

**To nie jest fakt o bazie, tylko fakt o człowieku.** Miary używane przez jedną
osobę są martwe dla drugiej, a sesja sprzątania potrzebuje innych niż przegląd
wakacji.

Stąd dwie zasady:

- **kolejność ręczna, nie samoucząca.** Automatyczne wypychanie najczęściej
  używanych na wierzch jest kuszące i byłoby błędem: lista, po której chodzi
  się z pamięci, nie może się przestawiać sama. Najwyżej podpowiedź przy
  często używanym wierszu;
- **podział listy rozwiniętej wedle tego, czego miara dotyczy**, a nie wedle
  typu danych — bo grupy odpowiadają wtedy różnym zadaniom:
  **właściwości zdjęcia** (ostrość, kolor, kompozycja, twarze — trwałe),
  **stan w archiwum** (nigdy nieoglądane, udostępnione, w serii, duplikat,
  zrzut ekranu — historia, nie obraz), **technika** (HDR, portret, wideo,
  rozdzielczość, brak lokalizacji).

### Warunki, które starzeją się razem ze zdjęciem

Zrzut ekranu sprzed tygodnia to notatka; ten sam sprzed pięciu lat to śmieć.
Tak samo „nigdy nieoglądane": świeże zdjęcie jeszcze nieobejrzane nie znaczy
nic, sprzed dziesięciu lat znaczy wszystko.

Warunki z grupy „stan w archiwum" chcą więc domyślnie wchodzić **razem
z warunkiem wieku**. Inaczej trzeba ustawić dwie rzeczy naraz, a nikt tego nie
zrobi, dopóki sam na to nie wpadnie.

## 7. Język wizualny dzisiaj

Systemowy ciemny motyw, akcent systemowy (niebieski), żółte gwiazdki, czerwień
zarezerwowana dla usuwania. Typografia systemowa, cyfry zawsze tabelaryczne
(liczniki nie mogą skakać). Ikony z SF Symbols.

Nagłówki sekcji: wersaliki, `caption2`, `semibold`, kolor trzeciorzędny.
Liczniki: `caption`, monospaced, drugorzędne; zero jest wyszarzone bardziej.

**Ikona aplikacji:** spektralna płytka i szklana lupa ze znakiem ćwiartek.
Ćwiartki zostają czytelne przy 16 px, spektrum robi się wtedy jedną barwną
plamą — i tak ma być.

## 8. Skala i jej konsekwencje

Archiwum rzędu 25 tysięcy zdjęć to nie jest liczba dekoracyjna. Wynikają z niej
ograniczenia, o które łatwo się potknąć projektując:

- **Licznik pozycji `3 / 37` nie działa.** `1447 / 25 191` nie odpowiada na
  pytanie „gdzie jestem". Odpowiedzią jest raczej data i ile zostało
  w bieżącym filtrze.
- **Zapętlenie zbioru jest pułapką.** Okrążenie archiwum bez ostrzeżenia
  rozbija całe założenie „wracasz tam, gdzie skończyłeś". Krańce muszą być
  widoczne.
- **Żaden pasek miniatur nie jest mapą całości** — to okno wokół bieżącego
  miejsca.
- **Miniatury ładują się asynchronicznie.** Każdy projekt musi wyglądać
  sensownie, gdy połowa kafelków jest jeszcze szara.

## 9. Kierunek: bliżej Adobe Bridge

**To jest główna wskazówka projektowa i ona porządkuje całą listę poniżej.**

Aplikacja zaczynała jako sortownik: jedno zdjęcie, jedna decyzja, dalej.
Odkrycie, ile gotowych danych leży pod biblioteką systemową, zmieniło jej
klasę — to ma być **przeglądarka archiwum**, a ocenianie schodzi do roli
jednej z czynności, które się w niej wykonuje. Punktem odniesienia jest Adobe
Bridge.

### Co z Bridge'a jest pożądane

- **Przestrzeń robocza z panelami zamiast przełączania trybów.** W Bridge
  filtr, siatka i podgląd są **jednocześnie na ekranie**. U nas siatka
  i pojedyncze zdjęcie są dziś osobnymi trybami i trzeba się między nimi
  przełączać. To jest największa różnica i największa decyzja do podjęcia.
- **Panel filtru z licznikami przy każdym kryterium.** Już jest — i został
  zrobiony właśnie z tego wzorca.
- **Zaznaczanie wielu kafelków i operacje na zaznaczeniu.** Nie ma wcale.
- **Widoczne sortowanie**, przestawiane jednym ruchem, nie ukryte w panelu.
- **Stosy** — Bridge grupuje serie zdjęć w jeden kafelek z licznikiem.
  Mamy wykryte serie, ale w siatce nie widać ich wcale.
- **Regulacja rozmiaru kafelka i alternatywne widoki** (siatka / lista
  ze szczegółami). Jest tylko suwak.
- **Zapamiętane układy** („workspaces") — przełączenie całego rozkładu paneli
  jednym kliknięciem, bo inaczej wygląda przeglądanie, a inaczej porównywanie.

### Czego z Bridge'a świadomie nie chcemy

- **Nie jest to menedżer plików.** Źródłem jest biblioteka systemowa, nie
  drzewo katalogów. Nie ma panelu folderów i nie będzie.
- **Nie ma etykiet kolorystycznych ani słów kluczowych.** Jedna skala ciągła
  i koniec — patrz rozstrzygnięcia w §3.
- **Nie ma gęstości Bridge'a.** Bridge pokazuje wszystko naraz i wygląda jak
  kokpit. To narzędzie ma dawać zdjęciu ekran; panele mają się chować.
- **Nie ma edycji, eksportu, wsadowego przetwarzania, publikacji.**

### Odpowiedź, która już padła

Pytanie brzmiało: czy okno na macOS staje się trzykolumnowe — filtr / siatka /
podgląd z metadanymi — z pojedynczym zdjęciem jako powiększeniem zaznaczonego
kafelka, a nie osobnym trybem?

**Tak.** Trzy kolumny jednocześnie na ekranie, a ocenianie z klawiatury zostaje
jako **pełny ekran na żądanie** (dwuklik albo `⏎`), nie jako tryb do
przełączania. To rozwiązuje obawę, która stała za tym pytaniem: pełny ekran się
nie traci, przestaje tylko być jedynym sposobem oglądania jednego zdjęcia.

Zaznaczanie na macOS: **pojedynczy klik zaznacza i karmi podgląd**, `⌘` i `⇧`
rozszerzają, dwuklik wchodzi w pełny ekran. Na iOS bez zmian — pojedyncze
stuknięcie otwiera zdjęcie.

Na iOS trzy kolumny nie wchodzą w grę i tam zostaje dzisiejszy podział. iPad
jest gdzieś pośrodku i zasługuje na własną odpowiedź.

## 10. Czego brakuje i gdzie potrzeba projektu

### Rozstrzygnięte w drugiej turze

Rozkład okna, zaznaczanie kafelków, stosy serii w siatce, kolejność wyprowadzona
na belkę nad siatką, żetony aktywnych warunków, grupowanie po dniu / serii /
osobie, swobodne porównywanie dwóch kadrów poza turniejem. Szczegóły w osobnym
przekazaniu projektowym, nie w tym dokumencie.

Jedna rzecz z tamtej tury pozostaje otwarta i blokuje implementację:
**grupowanie kłóci się z kolejnością**. Jeśli grupuję po dniu, a sortuję po
poruszeniu, to co znaczy „następne zdjęcie"? §4 mówi, że musi znaczyć jedno.
Propozycja: grupowanie **jest** kolejnością, tylko z nagłówkami — czyli kolejne
pozycje tej samej listy, wykluczające się z pozostałymi.

### Otwarte

**Zapisane zestawy warunków.** Sesja sprzątania to nie jeden wymiar, tylko
kombinacja: zrzuty ekranu, starsze niż jakiś czas, po dacie, z operacją na
całej puli na końcu. Takich przepisów będzie kilka i będą różne u różnych osób.
Do rozstrzygnięcia, czy to osobne pojęcie, czy część „przestrzeni roboczej"
razem z układem paneli.

**Roleta cech przy dwudziestu pozycjach.** Podział na trzy grupy z §6 pomaga,
ale dwadzieścia jednakowych wierszy to nadal ściana. Czy lista rozwinięta
potrzebuje własnego szukania?

**Komunikat o nowej mierze.** Sonda potrafi zauważyć, że system zaczął liczyć
coś, czego wcześniej nie liczył (§6). Nie wiadomo, jak o tym powiedzieć, żeby
nie było to ani natrętne, ani niewidoczne.

**Lokalizacja.** Interfejs jest dziś tylko polski. Żadne rozwiązanie nie może
zakładać długości słów ani zamkniętej liczby kategorii — segmentowane
przełączniki zostały z tego powodu usunięte z panelu filtru i nie powinny
wracać.

**iOS.** Świadomie odłożony: porządkujemy jedną platformę, potem tłumaczymy na
trudniejszą. Ale zaznaczanie, grupowanie, stosy i porównywanie nie mają tam
żadnej historii, a telefon jest urządzeniem, na którym aplikacja jest używana
w podróży i bez sieci. Model danych ma być wspólny, żeby to było tłumaczenie,
a nie przepisywanie.

**iPad.** Aplikacja działa, ale jest projektowana jako telefon na dużym
ekranie. Pasek boczny z macOS pasowałby tam znacznie lepiej niż arkusz.

**Stan pusty i pierwszy start.** Dziś to głównie komunikaty. Pierwsze
uruchomienie — prośba o dostęp do biblioteki, potem wczytanie cech, potem
wskazanie folderu wymiany — jest ciągiem, którego nikt nie zaprojektował.

**Widoczny stan synchronizacji.** Synchronizacja jest ręczna po obu stronach
i łatwo nie wiedzieć, że drugie urządzenie ma nowszą pracę. Dopóki tego nie
widać, wygląda to jak utrata pracy.

## 11. Słownik

| termin | znaczenie |
|---|---|
| **zbiór roboczy** | zdjęcia po filtrach, w bieżącej kolejności |
| **cecha** | miara policzona przez system Apple, nie ocena użytkownika |
| **waga** | liczba 0–5, prawdziwa ocena; gwiazdki są jej widokiem |
| **seria** | grupa podobnych zdjęć wykryta automatycznie |
| **odcisk wizualny** | wektor z Vision, po którym rozpoznajemy podobieństwo |
| **plik wymiany** | baza przewożąca oceny i cechy między urządzeniami |
| **wskaźnik miejsca** | zdjęcie, na którym stoi praca; wspólne dla wszystkich trybów |

## 12. Czego nie robić

- Nie dodawać drugiej listy zdjęć obok głównego zbioru roboczego.
- Nie robić trybu z pytania o zbiór.
- Nie wprowadzać jasnego motywu dla widoków ze zdjęciami.
- Nie używać kontrolek, których szerokość rośnie z liczbą pozycji
  (segmentowane przełączniki) — liczba kategorii nie jest zamknięta.
- Nie ukrywać krańców zbioru ani stanu „nic nie pasuje".
- Nie dokładać kroków między znalezieniem zdjęcia a decyzją o nim.
- Nie zakładać, że kolumna w bazie jest pusta, bez zmierzenia jej — trzy
  z czterech, które na to wyglądały, były wypełnione wartościami ujemnymi (§6).
- Nie przestawiać listy cech automatycznie wedle częstości używania (§6).
- Nie dawać suwakom progu sztywnego zakresu 0–1; granice pochodzą z pomiaru.
