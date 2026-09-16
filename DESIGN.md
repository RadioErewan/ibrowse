# ibrowse — brief projektowy

Dokument dla kogoś, kto ma projektować interfejs tej aplikacji. Opisuje, co
aplikacja robi, dla kogo, co jest już rozstrzygnięte i dlaczego, oraz gdzie
naprawdę potrzeba pomocy.

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

Jeden użytkownik, fotograf z archiwum **25 tysięcy zdjęć** zbieranym od 2007
roku. Zna się na narzędziach tej klasy (Adobe Bridge, Lightroom, Capture One)
i porównuje do nich. Sam o sobie mówi „zboczeniec ergonomiczny" w kwestii
interfejsów do oglądania obrazków — co znaczy tyle, że drobiazgi są tu
treścią, a nie wykończeniem.

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
3. **Cechy systemu** — pięć wierszy z licznikami: bez warunku / poruszone /
   źle naświetlone / zamknięte oczy / zrzuty ekranu. Przy dwóch pierwszych
   pojawia się suwak progu.
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

## 6. Język wizualny dzisiaj

Systemowy ciemny motyw, akcent systemowy (niebieski), żółte gwiazdki, czerwień
zarezerwowana dla usuwania. Typografia systemowa, cyfry zawsze tabelaryczne
(liczniki nie mogą skakać). Ikony z SF Symbols.

Nagłówki sekcji: wersaliki, `caption2`, `semibold`, kolor trzeciorzędny.
Liczniki: `caption`, monospaced, drugorzędne; zero jest wyszarzone bardziej.

**Ikona aplikacji:** spektralna płytka i szklana lupa ze znakiem ćwiartek.
Ćwiartki zostają czytelne przy 16 px, spektrum robi się wtedy jedną barwną
plamą — i tak ma być.

## 7. Skala i jej konsekwencje

25 tysięcy zdjęć to nie jest liczba dekoracyjna. Wynikają z niej ograniczenia,
o które łatwo się potknąć projektując:

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

## 8. Kierunek: bliżej Adobe Bridge

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

### Pytanie, od którego zależy reszta

**Czy okno na macOS staje się trzykolumnowe** — filtr / siatka / podgląd
z metadanymi — z pojedynczym zdjęciem jako powiększeniem zaznaczonego kafelka,
a nie osobnym trybem?

Za: to jest właśnie Bridge, znika przełączanie, zaznaczenie jednego kafelka
od razu pokazuje duży podgląd i metadane.

Przeciw: ocenianie z klawiatury na pełnym ekranie jest dziś bardzo dobre
i utrata pełnego ekranu byłaby realną stratą. Bridge rozwiązuje to osobnym
trybem przeglądu na pełnym ekranie — być może to jest odpowiedź: siatka
z podglądem jako stan domyślny, pełny ekran na żądanie.

Na iOS trzy kolumny nie wchodzą w grę i tam zostaje dzisiejszy podział. iPad
jest gdzieś pośrodku i zasługuje na własną odpowiedź.

## 9. Czego brakuje i gdzie potrzeba projektu

To jest właściwa lista zadań.

Uporządkowane wedle kierunku z §8, najważniejsze najpierw.

**Rozkład okna na macOS** — patrz pytanie na końcu §8. Od tej odpowiedzi
zależy wszystko poniżej, więc to jest pierwsze zadanie.

**Zaznaczanie pojedynczych kafelków.** Dziś operacje na grupie działają na
całym filtrze, bo zaznaczania nie ma w ogóle. Bridge to ma i to jest
odczuwalna dziura. Pytanie: jak pogodzić zaznaczanie z tym, że pojedyncze
stuknięcie na telefonie otwiera zdjęcie, a na Macu otwiera dwuklik.

**Serie widoczne w siatce.** Bridge robi z serii stos: jeden kafelek
z licznikiem, rozwijalny. Mamy wykryte serie i turniej, który je rozstrzyga,
ale w siatce nie widać ich w ogóle.

**Sortowanie na wierzchu.** Kolejność jest dziś w panelu filtru, a w Bridge
siedzi nad siatką i przestawia się jednym ruchem.

**Żetony aktywnych warunków w belce** — `(zrzuty ekranu ×) (2018–2019 ×)` nad
siatką. Na macOS z paskiem bocznym może być zbędne; na telefonie, gdzie filtr
jest arkuszem, prawdopodobnie konieczne.

**Grupowanie.** Po dniu, po serii, po osobie. System ma policzone momenty
i siedem tysięcy klastrów osób — dane są, sposobu pokazania nie ma.

**Swobodne porównywanie obok siebie**, poza turniejem. Dwa dowolne zdjęcia,
wybrane ręcznie.

**Lokalizacja.** Interfejs jest dziś tylko polski. Żadne rozwiązanie nie może
zakładać długości słów ani zamkniętej liczby kategorii — segmentowane
przełączniki zostały z tego powodu usunięte z panelu filtru i nie powinny
wracać.

**iPad.** Aplikacja działa, ale jest projektowana jako telefon na dużym
ekranie. Pasek boczny z macOS pasowałby tam znacznie lepiej niż arkusz.

**Stan pusty i pierwszy start.** Dziś to głównie komunikaty. Pierwsze
uruchomienie — prośba o dostęp do biblioteki, potem wczytanie cech, potem
wskazanie folderu wymiany — jest ciągiem, którego nikt nie zaprojektował.

## 10. Słownik

| termin | znaczenie |
|---|---|
| **zbiór roboczy** | zdjęcia po filtrach, w bieżącej kolejności |
| **cecha** | miara policzona przez system Apple, nie ocena użytkownika |
| **waga** | liczba 0–5, prawdziwa ocena; gwiazdki są jej widokiem |
| **seria** | grupa podobnych zdjęć wykryta automatycznie |
| **odcisk wizualny** | wektor z Vision, po którym rozpoznajemy podobieństwo |
| **plik wymiany** | baza przewożąca oceny i cechy między urządzeniami |
| **wskaźnik miejsca** | zdjęcie, na którym stoi praca; wspólne dla wszystkich trybów |

## 11. Czego nie robić

- Nie dodawać drugiej listy zdjęć obok głównego zbioru roboczego.
- Nie robić trybu z pytania o zbiór.
- Nie wprowadzać jasnego motywu dla widoków ze zdjęciami.
- Nie używać kontrolek, których szerokość rośnie z liczbą pozycji
  (segmentowane przełączniki) — liczba kategorii nie jest zamknięta.
- Nie ukrywać krańców zbioru ani stanu „nic nie pasuje".
- Nie dokładać kroków między znalezieniem zdjęcia a decyzją o nim.
