# lightbrary

Narzędzie do **wielokrotnego przeglądania archiwum zdjęć**: ocenianie,
porównywanie i usuwanie. Nie katalog i nie tagger — sortownik.

macOS i iOS, wszystko lokalnie, nic nie opuszcza urządzeń.

## Po co to jest

Archiwum, przez które nikt nigdy nie przejdzie, to nie archiwum — to kopia
zapasowa czegoś, co przestało istnieć w chwili zapisania. Problemem nie jest
miejsce na dysku, tylko dostępność.

Stąd jedno założenie, z którego wynika reszta: **praca rozłożona na lata
i wiele podejść**, nie na jedno posiedzenie. Wracasz po tygodniu i trafiasz
tam, gdzie skończyłeś. Pominięcie kosztuje tyle co ocena. Ocena jest względna,
bo gust się zmienia.

## Co potrafi

**Ocenianie** — jedna waga ciągła 0–5. Klawisze `1`–`5` ustawiają wprost,
`−`/`+` przesuwają o ćwierć punktu, na telefonie robi to gest w pionie.
Gwiazdki są tylko widokiem tej liczby.

**Parowanie** — wykrywa serie podobnych zdjęć (Vision, na urządzeniu)
i przepuszcza je przez turniej „które z tych dwóch jest lepsze". Seria z N
zdjęć kosztuje N−1 decyzji. Wynik zależy od tego, **kogo pokonałeś**, nie od
samego zwycięstwa.

**Filtrowanie** — zakres lat, stan oceny, zakres gwiazdek, cechy policzone
przez system, a na macOS także szukanie po treści: etykiety scen, imiona osób,
nazwy miejsc i tekst odczytany ze zdjęć. Każdy warunek niesie własny licznik,
więc widać, ile czego jest, **zanim** się go wybierze. Na macOS filtr jest
kolumną przy krawędzi okna, na telefonie arkuszem.

**Cechy** — poruszone, źle naświetlone, z zamkniętymi oczami, zrzuty ekranu.
Są **warunkiem filtru i porządkiem**, nie osobnym ekranem: „od najbardziej
poruszonych" to takie samo kryterium jak rok czy liczba gwiazdek, więc siatka,
ocenianie i pasek miniatur widzą ten sam zbiór w tej samej kolejności. Żadna
z tych liczb nie dotyka wagi zdjęcia — to pomiar systemu, nie ocena. Czyta je
macOS z baz biblioteki (wymaga Pełnego dostępu do dysku), a na telefon
przyjeżdżają synchronizacją, więc działają bez sieci.

**Metadane** — na macOS panel boczny z techniką zdjęcia i tym, co widzi
system. Na telefonie arkusz na żądanie.

**Pasek miniatur** pod zdjęciem (`T` na Macu) — widoczna kolejka: co będzie
następne i skąd się przyszło, ze skokiem dalej niż o jedno zdjęcie bez
wychodzenia do siatki.

**Podgląd 1:1** (`Z` na Macu, dwuklik na telefonie) — jedyne miejsce
z prawdziwymi pikselami, bo tylko tam da się ocenić ostrość.

**Synchronizacja** między urządzeniami przez plik w folderze, który sam
wskażesz — zwykle w iCloud Drive, ale równie dobrze Google Drive czy OneDrive.

## Czego potrzebujesz

- macOS 14+ / iOS 17+
- Xcode i [xcodegen](https://github.com/yonaskolb/XcodeGen)
- konto deweloperskie Apple — wystarczy darmowe

```bash
brew install xcodegen
```

Team ID trzymamy poza repozytorium. Utwórz `Local.xcconfig`:

```
IBROWSE_TEAM_ID = XXXXXXXXXX
```

## Budowanie

```bash
./install.sh        # macOS: buduje i uruchamia
./install.sh ios    # iPhone: buduje, podpisuje, instaluje
```

Przy **darmowym koncie podpis wygasa po 7 dniach** — wtedy po prostu
`./install.sh ios` jeszcze raz.

Identyfikator urządzenia w `install.sh` trzeba podmienić na własny:

```bash
xcrun devicectl list devices
```

## Uprawnienia

Aplikacja poprosi o dostęp do biblioteki zdjęć przy pierwszym uruchomieniu.

Panel metadanych i szukanie po treści wymagają dodatkowo **Pełnego dostępu do
dysku** (Ustawienia systemowe → Prywatność i bezpieczeństwo). Zgoda na
bibliotekę dotyczy PhotoKit, nie plików — a te dane leżą w bazach wewnątrz
pakietu biblioteki. Czytamy je wyłącznie do odczytu i niczego tam nie
zapisujemy.

## Synchronizacja

Na każdym urządzeniu wskaż **ten sam folder** (menu synchronizacji →
„wybierz folder wymiany"), potem „synchronizuj teraz".

Każde urządzenie pisze własny plik i czyta cudze — dzięki temu równoległe
zapisy nie mają jak wejść sobie w drogę. Odciski wizualne przyjeżdżają gotowe,
więc drugie urządzenie nie musi liczyć całego archiwum od nowa.

## Dlaczego tak, a nie inaczej

Powody wszystkich nieoczywistych decyzji — wraz z tym, co zmierzyliśmy
i co okazało się błędem — są w [DECYZJE.md](DECYZJE.md).

## Licencja

MIT.
