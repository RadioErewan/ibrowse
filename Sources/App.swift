import Photos
import SwiftData
import SwiftUI

@main
struct LightbraryApp: App {
    private let container = LightbraryApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                // Ciemno **zawsze**, nie za systemem.
                //
                // To nie jest kwestia gustu: jasne otoczenie sprawia, że
                // zdjęcie wydaje się ciemniejsze i mniej kontrastowe, niż
                // jest naprawdę. Aplikacja do oceniania zdjęć w jasnym
                // interfejsie kłamie o materiale, na podstawie którego
                // podejmujesz decyzje. Lightroom, Capture One i Bridge są
                // ciemne z tego samego powodu.
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
        #if os(macOS)
        // Belka tytułowa zostaje widoczna, bo teraz **coś w niej jest**.
        // Przy ukrytej toolbar nie ma się w co wpiąć i sterowanie znów
        // wylądowałoby we własnym pasku pod spodem.
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif
    }

    /// Skład trzymamy pod własnym identyfikatorem pakietu, nigdy pod domyślną
    /// nazwą SwiftData.
    ///
    /// Aplikacja jest niesandboksowana, więc `URL.applicationSupportDirectory`
    /// wskazuje wspólny `~/Library/Application Support`, a domyślny
    /// `default.store` jest tam zajęty przez inne programy (u Radka trzyma go
    /// systemowy `icloudmail`). Własny podkatalog to jedyny sposób, żeby mieć
    /// pewność, że dotykamy wyłącznie swoich danych.
    private static var storeURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "pl.3210.lightbrary", directoryHint: .isDirectory)
            .appending(path: "lightbrary.store")
    }

    /// Skład spod poprzedniej nazwy aplikacji, `ibrowse`.
    private static var legacyStoreURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "pl.3210.ibrowse", directoryHint: .isDirectory)
            .appending(path: "ibrowse.store")
    }

    /// Na tym etapie schemat jeszcze się rusza, a oceny to dane testowe.
    /// Zamiast pisać migracje do każdej zmiany modelu, odsuwamy niezgodny
    /// skład na bok — **nigdy go nie kasując**, bo skasowanego nie da się
    /// obejrzeć, gdyby okazał się potrzebny.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([Review.self, Fingerprint.self, Series.self, SeriesStamp.self])
        let url = storeURL

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        adoptLegacyStore(into: url)
        #if os(macOS)
        adoptLegacySettings()
        #endif

        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            archiveIncompatibleStore(at: url)
            return try! ModelContainer(for: schema, configurations: configuration)
        }
    }

    /// Przygarnia skład spod poprzedniej nazwy, **przenosząc go, nie kopiując**.
    ///
    /// Zmiana nazwy aplikacji zmienia identyfikator pakietu, a ten wyznacza
    /// katalog składu. Bez tego kroku aplikacja po przemianowaniu zastałaby
    /// pustkę: wszystkie oceny i wszystkie cechy zostałyby pod starą ścieżką,
    /// nietknięte i niewidoczne. Wygląda to jak utrata całej pracy, choć nic
    /// nie ginie — i właśnie dlatego trzeba to zrobić za użytkownika.
    ///
    /// Przenosimy tylko wtedy, gdy nowego składu **jeszcze nie ma**. Inaczej
    /// nowa praca zostałaby przykryta starą przy każdym uruchomieniu.
    ///
    /// Idą wszystkie trzy pliki: SQLite trzyma dziennik zapisu obok bazy
    /// i sam plik główny bez `-wal` to skład sprzed ostatnich zapisów.
    private static func adoptLegacyStore(into url: URL) {
        let files = FileManager.default
        guard !files.fileExists(atPath: url.path) else { return }

        let legacy = legacyStoreURL
        guard files.fileExists(atPath: legacy.path) else { return }

        for suffix in ["", "-shm", "-wal"] {
            let from = URL(fileURLWithPath: legacy.path + suffix)
            let to = URL(fileURLWithPath: url.path + suffix)
            guard files.fileExists(atPath: from.path) else { continue }
            try? files.moveItem(at: from, to: to)
        }
    }

    #if os(macOS)
    /// Przygarnia ustawienia spod poprzedniej nazwy.
    ///
    /// Domena ustawień to identyfikator pakietu, więc razem z nazwą zmienia się
    /// i ona. Dwie rzeczy naprawdę bolą przy jej utracie: **zakładka do folderu
    /// wymiany**, bo trzeba by go wskazywać od nowa, i **identyfikator
    /// urządzenia**, bo z nowym Mac zacząłby pisać drugi plik wymiany, a stary
    /// czytałby odtąd jako cudzy — 59 MB przy każdej synchronizacji, bez końca.
    ///
    /// Bierzemy tylko klucze z naszych przedrostków. Domena niesie też
    /// ustawienia okien dopisane przez sam system i nie ma powodu ich ruszać.
    ///
    /// Na iOS tego nie ma i nie może być: tam stara aplikacja to osobny
    /// kontener, do którego nowa nie ma dostępu. Telefon odzyskuje wszystko
    /// synchronizacją.
    private static func adoptLegacySettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "settings.adoptedFromIbrowse") else { return }
        guard let legacy = UserDefaults(suiteName: "pl.3210.ibrowse") else { return }

        let ours = ["library.", "sync.", "cull.", "pair.", "filters.", "features."]
        for (key, value) in legacy.dictionaryRepresentation()
        where ours.contains(where: key.hasPrefix) {
            // Nie nadpisujemy niczego, co nowa nazwa zdążyła już zapisać.
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "settings.adoptedFromIbrowse")
    }
    #endif

    /// Przenosi stary skład obok, ze znacznikiem czasu. Operujemy wyłącznie
    /// wewnątrz własnego katalogu i tylko na plikach o naszej nazwie.
    private static func archiveIncompatibleStore(at url: URL) {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let archived = URL(fileURLWithPath: url.path + ".\(stamp).bak" + suffix)
            try? FileManager.default.moveItem(at: file, to: archived)
        }
    }
}

/// Rozstrzyga stan uprawnień, zanim cokolwiek pokaże. Bez zgody na bibliotekę
/// aplikacja nie ma o czym mówić, więc to jest jedyny warunek wejścia.
struct RootView: View {
    @StateObject private var library = PhotoLibrary()
    @StateObject private var monitor = PerfMonitor()
    @StateObject private var similarity = Similarity()
    @StateObject private var albums = AlbumSync()
    @StateObject private var filters = Filters()
    @StateObject private var sync = LibrarySync()
    /// Cechy systemu wyjęte z bazy raz i trzymane obok — patrz `FeatureIndex`.
    @StateObject private var features = FeatureIndex()
    #if os(macOS)
    @StateObject private var importer = FeatureImport()
    #endif
    @State private var choosingFolder = false
    @State private var showingActions = false
    @Environment(\.modelContext) private var context

    @State private var mode: Mode = .grid
    @State private var showingFilters = false
    #if os(macOS)
    /// Pasek filtru jest **widokiem**, nie czynnością, więc jego stan przeżywa
    /// zamknięcie aplikacji tak samo jak stan inspektora metadanych.
    @AppStorage("filters.sidebar") private var sidebarVisible = true
    @AppStorage("preview.inspector") private var inspectorVisible = true
    @AppStorage("grid.thumb") private var thumbSize = 140.0
    @StateObject private var metadata = MetadataIndex()

    /// Pełny ekran nie jest trybem, tylko **stanem** przestrzeni roboczej.
    ///
    /// Wchodzi się w niego dwuklikiem w kafelek, wychodzi klawiszem `esc` —
    /// i wraca na to samo zdjęcie, bo wskaźnik miejsca jest wspólny. Gdyby był
    /// trybem, trzeba by go wybierać z listy i pamiętać, że się w nim jest.
    @State private var fullScreen = false

    /// Kolejka i para do porównania. Kolejkę podaje siatka, bo to ona zna
    /// zbiór roboczy; para to dwa wskaźniki na tę samą kolejkę.
    @State private var compareQueue: [PHAsset] = []
    @State private var comparePair: (a: String, b: String)?
    #endif

    /// Zaznaczone zdjęcia. Puste znaczy „operacje dotyczą całego filtru" —
    /// to jest domyślny stan i celowo użyteczny sam w sobie.
    @State private var selection: Set<String> = []

    /// Jedno miejsce, w którym stoi praca — wspólne dla wszystkich trybów.
    ///
    /// Każdy tryb je zapisuje i każdy je czyta, więc przełączanie trybów
    /// nigdy nie gubi kontekstu: siatka przewija się tam, gdzie skończyło
    /// się ocenianie, a ocenianie zaczyna tam, gdzie kliknąłeś w siatce.
    @State private var focusID: String?

    /// **Narzędzie**, nie widok.
    ///
    /// Do niedawna ta lista mieszała dwie różne rzeczy: co oglądam (siatka,
    /// cechy) i co robię (ocenianie, parowanie). Zestawienie cech było więc
    /// trybem, choć jest pytaniem o zbiór — i właśnie dlatego miało własną
    /// kolejkę, z której kliknięcie wyprowadzało donikąd. Teraz co oglądam
    /// rozstrzyga filtr, a tu zostaje wyłącznie to, co robię.
    enum Mode: String, CaseIterable, Identifiable {
        case grid = "siatka"
        case cull = "ocenianie"
        case pair = "parowanie"
        var id: String { rawValue }

        /// Na Macu **ocenianie zniknęło z listy**, bo przestało być trybem:
        /// przestrzeń robocza pokazuje zaznaczone zdjęcie w podglądzie, a pełny
        /// ekran wywołuje się dwuklikiem i opuszcza `esc`. Na telefonie zostaje,
        /// bo tam nie ma trzech kolumn i ocenianie **jest** osobnym ekranem.
        static var available: [Mode] {
            #if os(macOS)
            [.grid, .pair]
            #else
            allCases
            #endif
        }

        var icon: String {
            switch self {
            case .grid: "square.grid.2x2"
            case .cull: "star"
            case .pair: "rectangle.on.rectangle"
            }
        }
    }

    var body: some View {
        Group {
            switch library.authorization {
            case .authorized, .limited:
                if library.assets.isEmpty {
                    ProgressView("Wczytuję bibliotekę…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    main
                }
            case .notDetermined:
                Permission(
                    title: "Dostęp do biblioteki zdjęć",
                    message: "lightbrary czyta zdjęcia bezpośrednio z Twojej biblioteki. Nic nie opuszcza urządzenia.",
                    action: ("Poproś o dostęp", { Task { await library.requestAccess() } })
                )
            default:
                Permission(
                    title: "Brak dostępu",
                    message: "Odmówiono dostępu do biblioteki zdjęć. Włącz go w Ustawieniach systemowych → Prywatność i bezpieczeństwo → Zdjęcia.",
                    action: nil
                )
            }
        }
        .task { await library.start() }
        // Rozejrzenie się po folderze wymiany jest darmowe — czyta same daty
        // plików, nie ich zawartość — a odpowiada na pytanie „czy drugie
        // urządzenie ma nowszą pracę", którego aplikacja dotąd nie umiała zadać.
        .task { await sync.refreshFolderState() }
        // Cechy czytamy raz, do zwykłego słownika. Po wczytaniu z baz systemu
        // i po synchronizacji odświeżamy je jawnie — same z siebie się nie
        // zmieniają, więc nie ma czego pilnować w tle.
        .task { features.load(context: context) }
        // Synchronizacja przywozi cechy z drugiego urządzenia, więc po jej
        // zakończeniu słownik jest nieaktualny.
        .task(id: sync.isWorking) {
            guard !sync.isWorking else { return }
            features.load(context: context)
            await sync.refreshFolderState()
        }
        .task(id: library.assets.count) { filters.adopt(library.assets) }
        // Przy zmianie trybu zwalniamy podgrzane renditiony — inaczej
        // przejście z siatki do parowania trzyma w pamięci dwa komplety.
        .onChange(of: mode) { _, _ in library.releaseCache() }
        .task(id: library.assets.count) {
            guard !library.assets.isEmpty else { return }
            await similarity.loadGroups(context: context)
        }
        // Zmiana progu unieważnia cache przez `SeriesStamp`, więc serie
        // przeliczają się same — bez ręcznego czyszczenia czegokolwiek.
        .task(id: similarity.threshold) {
            guard !similarity.groups.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))  // po ustaniu ruchu suwakiem
            guard !Task.isCancelled else { return }
            await similarity.loadGroups(context: context)
        }
    }

    @ViewBuilder
    private var main: some View {
        #if os(iOS)
        // Na telefonie tryby idą na dolny pasek, a akcje chowają się w menu.
        // Poziomy pasek z Maca nie mieści się na szerokości kciuka: nazwy
        // trybów się ucinały, a przyciski rozlewały na trzy linie.
        TabView(selection: $mode) {
            ForEach(Mode.available) { item in
                NavigationStack {
                    screen(item)
                        .navigationTitle(item.rawValue)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            // Zakres lat ma własny przycisk, a nie pozycję
                            // w menu: arkusz otwierany z wnętrza menu mrugał
                            // i nie pokazywał się, bo dotknięcie zamyka menu
                            // razem z kotwicą, do której jest przypięty.
                            ToolbarItem(placement: .topBarLeading) { filterButton }
                            ToolbarItem(placement: .topBarTrailing) { actionsButton }
                        }
                }
                .tabItem { Label(item.rawValue, systemImage: item.icon) }
                .tag(item)
            }
        }
        // Arkusze wiszą na `TabView`, a **nie** w każdej zakładce z osobna.
        //
        // `TabView` trzyma wszystkie zakładki żywe naraz, więc trzy takie same
        // `.sheet` podpięte pod jeden `Bool` to trzy zgłoszenia do tej samej
        // prezentacji. SwiftUI wybiera wtedy jedno — i niekoniecznie to
        // z zakładki, w której stoisz. Objawiało się to tak, że filtr nie
        // otwierał się w siatce, za to wyskakiwał po przejściu do oceniania.
        .sheet(isPresented: $showingFilters) {
            FilterPanel(library: library, filters: filters, features: features)
        }
        .sheet(isPresented: $showingActions) {
            ActionsSheet(
                library: library, similarity: similarity,
                albums: albums, sync: sync
            )
        }
        #else
        // Sterowanie idzie do **belki tytułowej**, nie pod nią.
        //
        // Wcześniej był tu własny poziomy pasek z `HStack` i kreską pod
        // spodem — wzorzec z Windows i GTK, przyklejony pod tytułem. macOS ma
        // na to prawdziwy toolbar, który sam dba o odstępy, przezroczystość
        // przy przewijaniu i zwijanie nadmiaru pozycji. Mniej własnego kodu
        // i mniej obcego wyglądu naraz.
        // Filtr przy krawędzi okna, na stałe.
        //
        // `NavigationSplitView`, a nie własny `HStack` z kreską: sam rysuje
        // materiał paska, pamięta szerokość kolumny, daje się przeciągać
        // i dokłada do belki systemowy przycisk zwijania. Ten sam powód,
        // dla którego metadane siedzą w `.inspector`, a nie we własnej
        // kolumnie — patrz komentarz w `CullView`.
        NavigationSplitView(columnVisibility: sidebarBinding) {
            FilterPanel(library: library, filters: filters, features: features)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if comparePair != nil {
                    CompareView(
                        queue: compareQueue,
                        library: library,
                        pair: $comparePair,
                        orderName: filters.order.rawValue,
                        onClose: { comparePair = nil }
                    )
                } else if fullScreen {
                    // Pełny ekran zabiera całą szerokość: obie kolumny znikają,
                    // bo po to się w niego wchodzi. Wyjście `esc` przywraca je
                    // razem ze zdjęciem, na którym stała praca.
                    CullView(
                        library: library, filters: filters, monitor: monitor,
                        features: features, focusID: $focusID,
                        onExit: { fullScreen = false }
                    )
                } else {
                    workspace
                }
                StatusStrip(similarity: similarity, sync: sync, albums: albums) {
                    Task {
                        await sync.synchronise(
                            context: context, similarity: similarity, library: library
                        )
                        await sync.refreshFolderState()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: similarity.isWorking)
            .animation(.easeInOut(duration: 0.2), value: sync.isWorking)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if fullScreen {
                        Button {
                            fullScreen = false
                        } label: {
                            Label("wróć do siatki", systemImage: "chevron.left")
                        }
                        .help("esc")
                    } else {
                        // Ikony zamiast napisów: dwa segmenty z tekstem stały
                        // obok drugiego segmentowanego przełącznika i belka
                        // robiła się z tego jarmarkiem. Ikona nie zmienia też
                        // szerokości przy tłumaczeniu.
                        Picker("", selection: $mode) {
                            ForEach(Mode.available) { item in
                                Label(item.rawValue, systemImage: item.icon)
                                    .labelStyle(.iconOnly)
                                    .help(item.rawValue)
                                    .tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !fullScreen && mode == .grid && comparePair == nil {
                        thumbSlider
                        inspectorControl
                    }
                    fingerprintControl
                    featureControl
                    syncControl
                }
            }
            // Nieprzezroczysta belka. Domyślnie treść przenika pod toolbar,
            // co przy zwykłym widoku wygląda dobrze, ale przy inspektorze
            // dawało kaszę: pierwsze wiersze metadanych mieszały się
            // z przyciskami.
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        #endif
    }

    #if os(macOS)
    /// Środek przestrzeni roboczej. Inspektor wisi **tutaj**, a nie na całym
    /// detalu, bo w pełnym ekranie i w parowaniu nie ma czego w nim pokazywać,
    /// a `CullView` ma własny panel metadanych pod klawiszem `I`.
    @ViewBuilder
    private var workspace: some View {
        screen(mode)
            .inspector(isPresented: inspectorBinding) {
                PreviewInspector(
                    asset: previewAsset,
                    library: library,
                    metadata: metadata,
                    selectionCount: selection.count,
                    onFullScreen: { fullScreen = true }
                )
                .inspectorColumnWidth(min: 300, ideal: 390, max: 520)
            }
    }

    /// Podgląd pokazuje zdjęcie spod wskaźnika miejsca, bo każde kliknięcie
    /// w kafelek ustawia go razem z zaznaczeniem. Dzięki temu nie trzeba
    /// osobno pamiętać, które z zaznaczonych jest „tym pierwszym".
    private var previewAsset: PHAsset? {
        guard let focusID else { return nil }
        return library.asset(id: focusID)
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { inspectorVisible && mode == .grid && comparePair == nil },
                set: { inspectorVisible = $0 })
    }

    /// Tylko przełącznik podglądu — pasek filtru ma **systemowy** przycisk
    /// zwijania po lewej stronie belki i drugi, własny, byłby powtórzeniem.
    ///
    /// Pierwsze podejście dało tu trzy przyciski układów paneli, zgodnie
    /// z przekazaniem projektowym. W belce wyszły z tego trzy osobne bąble
    /// dublujące systemowy przełącznik — projekt nie wiedział, że macOS jeden
    /// już daje. Ta sama para co przy metadanych w `CullView`.
    @ViewBuilder
    private var inspectorControl: some View {
        Button {
            inspectorVisible.toggle()
        } label: {
            Label("podgląd", systemImage: "sidebar.trailing")
                .labelStyle(.iconOnly)
        }
        .help("Podgląd i metadane")
    }

    /// Sam suwak, bez ikon po bokach.
    ///
    /// Ikony „mniejsze" i „większe" to wzorzec z panelu ustawień, gdzie mają
    /// miejsce. W belce narzędzi wchodzą pod zaokrągloną krawędź grupy
    /// i wyglądają na obcięte — a przy suwaku rozmiaru kafelka niczego nie
    /// tłumaczą, bo skutek widać natychmiast w siatce.
    private var thumbSlider: some View {
        Slider(value: $thumbSize, in: 80...280) { Text("rozmiar kafelka") }
            .labelsHidden()
            .frame(width: 120)
            .help("rozmiar kafelka")
    }

    /// `NavigationSplitView` mówi o widoczności trzema stanami, a nas
    /// interesują dwa. `.all` i `.detailOnly` to jedyne, które ma sens przy
    /// dwóch kolumnach; `.automatic` zostawiamy systemowi przy pierwszym
    /// otwarciu i zapisujemy dopiero to, co użytkownik wybierze sam.
    private var sidebarBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible && !fullScreen && comparePair == nil ? .all : .detailOnly },
            set: { if !fullScreen && comparePair == nil { sidebarVisible = $0 != .detailOnly } }
        )
    }
    #endif

    @ViewBuilder
    private func screen(_ mode: Mode) -> some View {
        switch mode {
        case .grid:
            GridView(
                library: library,
                monitor: monitor,
                filters: filters,
                features: features,
                selection: $selection,
                focusID: $focusID,
                onOpen: { asset in
                    focusID = asset.localIdentifier
                    #if os(macOS)
                    // Na Macu dwuklik wchodzi w pełny ekran, nie w osobny tryb.
                    fullScreen = true
                    #else
                    self.mode = .cull
                    #endif
                },
                onCompare: { queue, a, b in
                    #if os(macOS)
                    compareQueue = queue
                    comparePair = (a: a, b: b)
                    #endif
                }
            )
        case .cull:
            CullView(
                library: library, filters: filters, monitor: monitor,
                features: features, focusID: $focusID
            )
        case .pair: PairView(library: library, similarity: similarity, focusID: $focusID)
        }
    }

    /// Wejście do akcji na telefonie. Sam przycisk — cała zawartość mieszka
    /// w arkuszu, bo `Menu` na iOS zamyka się przy każdej przebudowie widoku,
    /// a tutaj przebudowa jest pewna: liczba serii i postęp liczenia zmieniają
    /// się w trakcie. Stąd brało się pulsowanie.
    @ViewBuilder
    private var actionsButton: some View {
        Button { showingActions = true } label: {
            Image(systemName: similarity.isWorking || sync.isWorking
                  ? "ellipsis.circle.fill" : "ellipsis.circle")
        }
    }

    /// Wczytanie cech jest jawną operacją na całym archiwum — tak samo jak
    /// liczenie odcisków i dokładnie z tego samego powodu. Mieszkało kiedyś
    /// w zakładce cech; po jej likwidacji należy tu, obok pozostałych
    /// poleceń działających na całości.
    #if os(macOS)
    @ViewBuilder
    private var featureControl: some View {
        busyButton(
            title: "wczytaj cechy",
            icon: "camera.metering.spot",
            busy: importer.isWorking,
            help: importer.summary ?? "Czyta ostrość, ekspozycję i twarze z baz biblioteki Zdjęć"
        ) {
            Task {
                await importer.run(context: context, library: library)
                features.load(context: context)
            }
        }
    }
    #endif

    /// Liczenie odcisków jest jawną, jednorazową operacją — nie chcę, żeby
    /// aplikacja po cichu mieliła całe archiwum przy pierwszym starcie.
    ///
    /// W belce zostaje **sama akcja**. Czułość grupowania i liczba serii to
    /// ustawienia jednego trybu, nie polecenia — wisiały tu przez cały czas,
    /// także w siatce, gdzie nie znaczą nic. Belka robiła się od tego wysoka
    /// i zatłoczona, a inspektor wjeżdżał pod ten gąszcz.
    @ViewBuilder
    private var fingerprintControl: some View {
        busyButton(
            title: "policz odciski",
            icon: "wand.and.stars",
            busy: similarity.isWorking,
            help: "Liczy odciski wizualne dla całej biblioteki"
        ) {
            Task {
                await similarity.computeFingerprints(
                    for: library.assets, library: library, context: context
                )
            }
        }
    }

    /// Przycisk, który w trakcie pracy **zostaje przyciskiem**.
    ///
    /// Wcześniej zamieniał się w sam kręciołek. Kręciołek jest węższy niż
    /// przycisk z ikoną, więc cała grupa w belce kurczyła się po kliknięciu
    /// i sąsiednie ikony podjeżdżały pod kursor — to, w co się celowało,
    /// uciekało. Teraz kręciołek siedzi w miejscu ikony, w ramce tej samej
    /// wielkości, a przycisk jest tylko wyłączony.
    private func busyButton(
        title: String, icon: String, busy: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: icon).opacity(busy ? 0 : 1)
                if busy { ProgressView().controlSize(.mini) }
            }
            .frame(width: 18, height: 16)
            .accessibilityLabel(title)
        }
        .disabled(busy)
        .help(help)
    }
}

extension RootView {
    /// Jedno wejście do wszystkich warunków. Etykieta mówi, co jest nałożone,
    /// bo filtr założony wczoraj i zapomniany wygląda jak zniknięte archiwum.
    @ViewBuilder
    fileprivate var filterButton: some View {
        Button { showingFilters = true } label: {
            Label(filterLabel, systemImage: filters.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
            #if os(iOS)
                .font(.caption)
            #endif
        }
    }

    fileprivate var filterLabel: String {
        var parts: [String] = []

        if !filters.query.isEmpty { parts.append("„\(filters.query)”") }

        if filters.onlyMarked { parts.append("do usunięcia") }
        if !filters.grades.isEmpty {
            let sorted = filters.grades.sorted { $0.rawValue < $1.rawValue }
            parts.append(sorted.map { $0.isUnrated ? "bez oceny" : "★\($0.rawValue)" }
                .joined(separator: ","))
        }

        let from = filters.fromYear, to = filters.toYear
        if from > 0 || to < 9999 {
            if from > 0 && to >= 9999 { parts.append("od \(String(from))") }
            else if from <= 0 { parts.append("do \(String(to))") }
            else { parts.append(from == to ? String(from) : "\(String(from))–\(String(to))") }
        }

        return parts.isEmpty ? "filtr" : parts.joined(separator: " · ")
    }

    /// Synchronizacja jest ręczna i wsadowa. Zapis przez PhotoKit jest wolny,
    /// więc wołanie go po każdej ocenie zabiłoby tempo pracy.
    ///
    /// Dwa transporty obok siebie, bo robią co innego. **Albumy** pokazują
    /// gwiazdki w systemowych Zdjęciach — to jedyny sposób, żeby ocena była
    /// widoczna poza tą aplikacją. **Plik wymiany** przenosi całą resztę:
    /// dokładną wagę, liczbę ocen, odciski i stan turniejów.
    @ViewBuilder
    fileprivate var syncControl: some View {
        if albums.isSyncing || sync.isWorking {
            ProgressView().controlSize(.small)
        } else {
            Menu {
                Button {
                    Task {
                        // Plik przed albumami: album niesie samą gwiazdkę
                        // i stempluje ją bieżącym czasem, więc puszczony
                        // pierwszy wygrywałby z dokładną wagą z pliku.
                        await sync.synchronise(context: context, similarity: similarity, library: library)
                        _ = albums.pull(into: context)
                        await albums.push(from: context)
                    }
                } label: {
                    Label("synchronizuj teraz", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!SyncFolder.isChosen)

                Divider()

                Button {
                    chooseFolder()
                } label: {
                    Label(
                        SyncFolder.isChosen ? "zmień folder wymiany…" : "wybierz folder wymiany…",
                        systemImage: "folder"
                    )
                }

                if let name = SyncFolder.displayName {
                    Text("folder: \(name)")
                }
                if let note = sync.summary {
                    Divider()
                    Text(note)
                }
            } label: {
                Label("synchronizuj", systemImage: "arrow.triangle.2.circlepath")
            }
            #if os(iOS)
            .fileImporter(
                isPresented: $choosingFolder, allowedContentTypes: [.folder]
            ) { result in
                if case .success(let url) = result { try? SyncFolder.remember(url) }
            }
            #endif
        }
    }

    /// Folder wskazuje użytkownik, bo to jego iCloud Drive i jego dane —
    /// aplikacja nie ma prawa zakładać, gdzie mają leżeć.
    fileprivate func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Wybierz"
        panel.message = "Folder wymiany — najlepiej w iCloud Drive, żeby jeździł między urządzeniami."
        if panel.runModal() == .OK, let url = panel.url {
            try? SyncFolder.remember(url)
        }
        #else
        choosingFolder = true
        #endif
    }
}


private struct Permission: View {
    let title: String
    let message: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
