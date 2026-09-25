import Photos
import SwiftData
import SwiftUI

@main
struct LightbraryApp: App {
    private let container = LightbraryApp.makeContainer()

    init() {
        Self.recordUncaughtExceptions()
    }

    /// Zapisuje **treść** wyjątku, zanim program zginie.
    ///
    /// Systemowy raport awarii pokazuje sam stos wywołań. Przy wyjątkach
    /// AppKit-u to za mało: cały stos składa się z ramek systemowych, a jedyne,
    /// co naprawdę mówi, co się stało, to `reason` — zdanie z asercji, którego
    /// w raporcie nie ma. Przy awarii układu okna na obcym Macu zostawało
    /// zgadywanie z samych adresów, bo ten jeden napis przepadał.
    ///
    /// Plik ląduje tam, gdzie trafiają logi aplikacji, żeby dało się o niego
    /// poprosić jednym zdaniem: `~/Library/Logs/lightbrary-exception.log`.
    private static func recordUncaughtExceptions() {
        NSSetUncaughtExceptionHandler { exception in
            let report = """
                \(Date())
                \(exception.name.rawValue)
                \(exception.reason ?? "bez opisu")

                \(exception.callStackSymbols.joined(separator: "\n"))

                """
            FileHandle.standardError.write(Data(report.utf8))

            guard let logs = try? FileManager.default.url(
                for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            ).appending(path: "Logs/lightbrary-exception.log") else { return }
            // Dopisujemy, bo awaria potrafi się powtórzyć, a poprzedni przebieg
            // bywa tym, który mówi więcej.
            if let handle = try? FileHandle(forWritingTo: logs) {
                handle.seekToEndOfFile()
                handle.write(Data(report.utf8))
                try? handle.close()
            } else {
                try? Data(report.utf8).write(to: logs)
            }
        }
    }

    #if os(macOS)
    @StateObject private var updates = UpdateCheck.shared
    #endif

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
                #if os(macOS)
                .sheet(isPresented: $updates.isPresenting) { UpdateSheet() }
                #endif
        }
        .modelContainer(container)
        #if os(macOS)
        // Rozmiar startowy **tylko przy pierwszym otwarciu** — potem macOS
        // pamięta ramkę okna sam.
        //
        // Bez tego świeża instalacja dostawała okno w domyślnym rozmiarze
        // SwiftUI, a to bywa węższe niż suma minimalnych szerokości obu paneli
        // bocznych: 190 na filtry plus 300 na podgląd, czyli 490 punktów, zanim
        // siatka dostanie pierwszy piksel. System musiał wtedy któryś panel
        // zamknąć — i to właśnie zamykanie domykało pętlę, przez którą program
        // ginął przy pierwszym uruchomieniu. Pętle są już rozerwane w obu
        // bindingach, ale okno, w którym wszystko się mieści, jest po prostu
        // lepszym pierwszym wrażeniem niż okno, które samo coś chowa.
        .defaultSize(width: 1280, height: 820)
        .commands {
            // Pod „O programie", czyli tam, gdzie każdy Mac trzyma tę pozycję.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.check() }
            }
            LibraryCommands()
        }
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
        clearStaleWindowState()
        #endif

        let configuration = ModelConfiguration(schema: schema, url: url)
        if let container = try? ModelContainer(for: schema, configurations: configuration) {
            return container
        }

        // Pierwsza próba padła — najczęstszy powód to schemat sprzed migracji,
        // więc odsuwamy stary plik i próbujemy jeszcze raz.
        archiveIncompatibleStore(at: url)
        if let container = try? ModelContainer(for: schema, configurations: configuration) {
            return container
        }

        // Druga próba padła z **innego** powodu — pełny dysk, brak praw do
        // katalogu, iCloud Drive trzymające go w chmurze. Odsunięcie pliku
        // tego nie naprawia, a `try!` w tym miejscu zabijał aplikację bez
        // śladu: trzy zgłoszenia „nigdy się nie otworzyła" po instalacji na
        // obcym Macu wyglądają dokładnie tak. Skład w pamięci nie przeżywa
        // zamknięcia okna, ale człowiek zobaczy program, a nie czarny ekran —
        // i będzie miał co opisać w zgłoszeniu.
        let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return (try? ModelContainer(for: schema, configurations: fallback))
            ?? (try! ModelContainer(for: schema))
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
    /// **Jednorazowe skasowanie zapisanego położenia okna i podziału kolumn.**
    ///
    /// macOS zapisuje ramkę okna i stan `NSSplitView` pod kluczem, w którego
    /// nazwie siedzi **pełny typ widoku głównego**. Dodanie czegokolwiek do
    /// hierarchii — u nas arkusza z aktualizacjami — zmienia ten typ, więc
    /// system traktuje okno jako nowe i daje mu domyślny, ciasny rozmiar.
    /// U pierwszej testerki wyszło z tego okno 1143×450 z panelem filtrów
    /// zapisanym jako **zwinięty**, przy jednoczesnym żądaniu SwiftUI, żeby był
    /// widoczny. Dwa niezgodne źródła prawdy o tej samej kolumnie zapętlały
    /// układ okna i zabijały program, zanim cokolwiek się pokazało.
    ///
    /// Samo naprawienie kodu nie wystarczy, bo **zły zapis przeżywa
    /// aktualizację**: każdy, kto uruchomił którąkolwiek wcześniejszą wersję,
    /// ma go u siebie i dostałby tę samą awarię mimo poprawek. Ci ludzie to
    /// dokładnie pierwsi testerzy — czyli ostatnie osoby, które powinny
    /// zobaczyć ten błąd po raz drugi.
    ///
    /// Kasujemy **tylko własne** klucze okienne, raz, i zapamiętujemy że już
    /// to zrobiliśmy. Kosztem jest zapomniane położenie okna przy jednej
    /// aktualizacji — cena, której nikt nie zauważy, w zamian za program,
    /// który w ogóle wstaje.
    private static func clearStaleWindowState() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "settings.clearedWindowState") else { return }

        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame") || key.hasPrefix("NSSplitView Subview Frames") {
            defaults.removeObject(forKey: key)
        }

        // Drugie, osobne miejsce, w którym macOS trzyma stan okna — mechanizm
        // przywracania po restarcie, kompletnie niezależny od `UserDefaults`.
        // Log od kolejnego testera pokazał `hasPersistentStateToRestore=1`:
        // system miał zakodowany stan czekający na przywrócenie, którego
        // powyższe czyszczenie w ogóle nie dotyka. Jeśli w tym zakodowanym
        // stanie siedzi ta sama sprzeczność co w kluczach `NSSplitView`, ten
        // sam wyjątek wróci trzecią drogą.
        if let saved = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appending(path: "Saved Application State/pl.3210.lightbrary.savedState") {
            try? FileManager.default.removeItem(at: saved)
        }

        defaults.set(true, forKey: "settings.clearedWindowState")
    }

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

extension FocusedValues {
    /// Biblioteka należy do okna (`RootView`), a menu do aplikacji — polecenie
    /// sięga do niej przez wartość wystawioną przez okno.
    @Entry var reloadLibrary: (() -> Void)?
    /// Zaznaczenie wszystkich zdjęć w filtrze — wystawia je siatka, gdy jest
    /// na ekranie.
    @Entry var selectAllPhotos: (() -> Void)?
}

#if os(macOS)
/// Siatka bezpieczeństwa obok obserwatora zmian, w menu zamiast w belce:
/// tam nie ma miejsca, a przycisk kuszący przy każdym opóźnieniu iCloud
/// obiecywałby więcej, niż może dać.
struct LibraryCommands: Commands {
    @FocusedValue(\.reloadLibrary) private var reload
    @FocusedValue(\.selectAllPhotos) private var selectAllPhotos

    var body: some Commands {
        // ⌘A w siatce zaznacza zdjęcia, w polu tekstowym — tekst. Standardowe
        // „Select All" idzie tylko do pierwszego respondera, a siatka SwiftUI
        // nim nie jest, więc dotąd klawisz nie robił nic. Grupę zastępujemy
        // całą, więc wytnij, kopiuj i wklej wracają tu jako zwykłe akcje dla
        // pól tekstowych.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x")
            Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                .keyboardShortcut("c")
            Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                .keyboardShortcut("v")
            Button("Select All") {
                if let selectAllPhotos, !(NSApp.keyWindow?.firstResponder is NSText) {
                    selectAllPhotos()
                } else {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("a")
        }
        CommandGroup(before: .toolbar) {
            Button("Reload Library") { reload?() }
                .keyboardShortcut("r")
                .disabled(reload == nil)
            Divider()
        }
    }
}
#endif

/// Rozstrzyga stan uprawnień, zanim cokolwiek pokaże. Bez zgody na bibliotekę
/// aplikacja nie ma o czym mówić, więc to jest jedyny warunek wejścia.
struct RootView: View {
    @StateObject private var library = PhotoLibrary()
    // `@State`, nie `@StateObject`: ten drugi subskrybuje zmiany i widok
    // główny przebudowywał się — ze `NavigationSplitView` włącznie — przy
    // każdym tiku pomiaru i każdym wczytanym obrazku. Obiekt ma tylko żyć
    // tyle, co widok; obserwuje go wyłącznie `PerfOverlay`.
    @State private var monitor = PerfMonitor()
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
    @Environment(\.scenePhase) private var scenePhase
    /// Odłożony zapis własnych decyzji. W obiekcie, nie w `@State` wprost:
    /// zadanie zmienia się przy **każdym** zapisie bazy, czyli przy każdej
    /// ocenie, a każda zmiana `@State` przebudowywała widok główny — całe okno
    /// ze `NavigationSplitView` i paskiem narzędzi, po 0,6–0,9 s na ocenę.
    @State private var pendingWrite = PendingTask()

    @State private var mode: Mode = .grid
    @State private var showingFilters = false
    #if os(macOS)
    /// Pasek filtru jest **widokiem**, nie czynnością, więc jego stan przeżywa
    /// zamknięcie aplikacji tak samo jak stan inspektora metadanych.
    @AppStorage("filters.sidebar") private var sidebarVisible = true
    @AppStorage("preview.inspector") private var inspectorVisible = true
    @AppStorage("grid.thumb") private var thumbSize = 140.0
    // `@State`, nie `@StateObject`: widok główny tylko przekazuje metadane
    // dalej, a obserwując je przebudowywał całe okno przy każdym zdjęciu.
    @State private var metadata = MetadataIndex()

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

    /// Jedno miejsce, w którym stoi praca, i zaznaczenie — wspólne dla
    /// wszystkich trybów, więc przełączanie trybów nigdy nie gubi kontekstu:
    /// siatka przewija się tam, gdzie skończyło się ocenianie, a ocenianie
    /// zaczyna tam, gdzie kliknąłeś w siatce. Puste zaznaczenie znaczy
    /// „operacje dotyczą całego filtru".
    ///
    /// `@State` z obiektem, **nie obserwowany** tutaj — patrz `Focus`.
    @State private var focus = Focus()

    /// **Narzędzie**, nie widok.
    ///
    /// Do niedawna ta lista mieszała dwie różne rzeczy: co oglądam (siatka,
    /// cechy) i co robię (ocenianie, parowanie). Zestawienie cech było więc
    /// trybem, choć jest pytaniem o zbiór — i właśnie dlatego miało własną
    /// kolejkę, z której kliknięcie wyprowadzało donikąd. Teraz co oglądam
    /// rozstrzyga filtr, a tu zostaje wyłącznie to, co robię.
    /// Jak w `Filters.Feature`: `rawValue` jest kluczem, `label` napisem.
    enum Mode: String, CaseIterable, Identifiable {
        case grid, cull, pair
        var id: String { rawValue }

        var label: String {
            switch self {
            case .grid: String(localized: "grid")
            case .cull: String(localized: "rate")
            case .pair: String(localized: "pair up")
            }
        }

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
                // **Zawsze** ta sama struktura okna, także w trakcie
                // ładowania — patrz komentarz przy `screen(_:)`.
                main
            case .notDetermined:
                Permission(
                    title: "Photo library access",
                    message: "lightbrary reads photos straight from your library. Nothing leaves this device.",
                    action: ("Request access", { Task { await library.requestAccess() } })
                )
            default:
                Permission(
                    title: "No access",
                    message: "Photo library access was denied. Turn it on in System Settings → Privacy & Security → Photos.",
                    action: nil
                )
            }
        }
        .focusedSceneValue(\.reloadLibrary, { library.reload() })
        .task {
            // Przed `start()`, bo pierwsze wczytanie od razu podaje stan natywny.
            library.onNativeSnapshot = { NativeSync.apply($0, in: context) }
            await library.start()
        }
        // Rozejrzenie się po folderze wymiany jest darmowe — czyta same daty
        // plików, nie ich zawartość — a odpowiada na pytanie „czy drugie
        // urządzenie ma nowszą pracę", którego aplikacja dotąd nie umiała zadać.
        .task { await sync.refreshFolderState() }
        // Synchronizacja sama z siebie: przy powrocie na wierzch i co dwie
        // minuty. Czyta tylko pliki, których data się zmieniła — sprawdzenie
        // nic nie kosztuje, a ręczne „sync now" dalej czyta wszystko.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await Trace.measure("sync.auto") { await sync.autoSync(context: context, similarity: similarity, library: library) } }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                await sync.autoSync(context: context, similarity: similarity, library: library)
            }
        }
        // Własne decyzje wypisujemy 20 s po ostatnim zapisie do bazy, żeby
        // drugie urządzenie miało co przeczytać bez ręcznej synchronizacji.
        // Seria ocen to jeden zapis pliku, nie jeden na klawisz.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            pendingWrite.replace {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await sync.writeOwnDecisions(context: context, library: library)
            }
        }
        // Cechy czytamy raz, do zwykłego słownika. Po wczytaniu z baz systemu
        // i po synchronizacji odświeżamy je jawnie — same z siebie się nie
        // zmieniają, więc nie ma czego pilnować w tle.
        //
        // Ten sam `.task` wczytuje je przy starcie (rusza przy pojawieniu się
        // okna) i po synchronizacji, która przywozi cechy z drugiego
        // urządzenia. Osobny `.task` na sam start czytał wszystko drugi raz.
        .task(id: sync.isWorking) {
            guard !sync.isWorking else { return }
            await Trace.measure("features.load") { await features.load(context: context) }
            filters.adoptTerms(features.terms)
            await sync.refreshFolderState()
        }
        .task(id: library.assets.count) { Trace.measure("filters.adopt") { filters.adopt(library.assets) } }
        // Przy zmianie trybu zwalniamy podgrzane renditiony — inaczej
        // przejście z siatki do parowania trzyma w pamięci dwa komplety.
        .onChange(of: mode) { _, _ in library.releaseCache() }
        .task(id: library.assets.count) {
            guard !library.assets.isEmpty else { return }
            await Trace.measure("similarity.load") { await similarity.loadGroups(context: context) }
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
                        .navigationTitle(item.label)
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
                .tabItem { Label(item.label, systemImage: item.icon) }
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
                albums: albums, sync: sync,
                onPairTab: mode == .pair
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
                        orderName: filters.order.label,
                        onClose: { comparePair = nil }
                    )
                } else if fullScreen {
                    // Pełny ekran zabiera całą szerokość: obie kolumny znikają,
                    // bo po to się w niego wchodzi. Wyjście `esc` przywraca je
                    // razem ze zdjęciem, na którym stała praca.
                    CullView(
                        library: library, filters: filters, monitor: monitor,
                        features: features, focus: focus,
                        onExit: { fullScreen = false }
                    )
                } else {
                    workspace
                }
                StatusStrip(similarity: similarity, sync: sync) {
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
                            Label("back to the grid", systemImage: "chevron.left")
                        }
                        .help("esc")
                        // Esc wychodzi z pełnego ekranu także wtedy, gdy
                        // klawiatura nie trafia w sam widok (fokus gdzie
                        // indziej) — skrót okna działa niezależnie od fokusu.
                        .keyboardShortcut(.cancelAction)
                    } else {
                        // Ikony zamiast napisów: dwa segmenty z tekstem stały
                        // obok drugiego segmentowanego przełącznika i belka
                        // robiła się z tego jarmarkiem. Ikona nie zmienia też
                        // szerokości przy tłumaczeniu.
                        Picker("", selection: $mode) {
                            ForEach(Mode.available) { item in
                                Label(item.label, systemImage: item.icon)
                                    .labelStyle(.iconOnly)
                                    .help(item.label)
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
                FocusedPreview(
                    focus: focus,
                    library: library,
                    metadata: metadata,
                    onFullScreen: { fullScreen = true }
                )
                .inspectorColumnWidth(min: 300, ideal: 390, max: 520)
            }
    }


    /// **Zapis poza przebiegiem układu, i tylko gdy to decyzja człowieka.**
    ///
    /// Setter bindingu jest wołany przez SwiftUI *w trakcie* układania okna —
    /// także wtedy, gdy to nie użytkownik zamyka panel, tylko system, bo panel
    /// przestał się mieścić. Zapis do `@AppStorage` w tym momencie unieważnia
    /// widok w środku jego własnego układu: kolumna zmienia szerokość,
    /// `setFrameSize:` rozsyła powiadomienia, ktoś prosi o nowe ograniczenia,
    /// prośba idzie w górę do okna — a okno jest w połowie poprzedniego
    /// przeliczenia i rzuca wyjątkiem. Tak ginęła aplikacja na czterech obcych
    /// Makach, zawsze przy pierwszym uruchomieniu.
    ///
    /// Trzy zabezpieczenia, w kolejności ważności:
    /// 1. **Nie zapisujemy stanu, którego nie kontrolujemy** — gdy `get` i tak
    ///    zwraca fałsz z innego powodu (tryb, porównanie), zamknięcie panelu
    ///    nie jest wyborem użytkownika i nie ma czego utrwalać.
    /// 2. **Nie zapisujemy echa** — wartość równa obecnej nie niesie decyzji,
    ///    a zapis i tak unieważniłby widok.
    /// 3. **Zapis dopiero po zakończeniu układu** — rozrywa cykl nawet wtedy,
    ///    gdy pierwsze dwa warunki przepuszczą prawdziwą zmianę.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { inspectorVisible && mode == .grid && comparePair == nil },
            set: { wanted in
                guard mode == .grid, comparePair == nil else { return }
                guard wanted != inspectorVisible else { return }
                DispatchQueue.main.async { inspectorVisible = wanted }
            }
        )
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
            Label("preview", systemImage: "sidebar.trailing")
                .labelStyle(.iconOnly)
        }
        .help("Preview and metadata")
    }

    /// Sam suwak, bez ikon po bokach.
    ///
    /// Ikony „mniejsze" i „większe" to wzorzec z panelu ustawień, gdzie mają
    /// miejsce. W belce narzędzi wchodzą pod zaokrągloną krawędź grupy
    /// i wyglądają na obcięte — a przy suwaku rozmiaru kafelka niczego nie
    /// tłumaczą, bo skutek widać natychmiast w siatce.
    private var thumbSlider: some View {
        Slider(value: $thumbSize, in: 80...280) { Text("tile size") }
            .labelsHidden()
            .frame(width: 120)
            .help("tile size")
    }

    /// `NavigationSplitView` mówi o widoczności trzema stanami, a nas
    /// interesują dwa. `.all` i `.detailOnly` to jedyne, które ma sens przy
    /// dwóch kolumnach; `.automatic` zostawiamy systemowi przy pierwszym
    /// otwarciu i zapisujemy dopiero to, co użytkownik wybierze sam.
    /// Zapis odroczony i odsiany z ech — dokładnie z tego samego powodu co
    /// w `inspectorBinding`, patrz tamtejszy komentarz. To są **dwie osobne
    /// pętle** i obie trzeba było rozerwać: przy wąskim oknie system zamyka
    /// raz jeden panel, raz drugi, i stąd ten sam wyjątek potrafił przychodzić
    /// dwiema różnymi drogami przez `NSHostingView`.
    private var sidebarBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible && !fullScreen && comparePair == nil ? .all : .detailOnly },
            set: { wanted in
                guard !fullScreen, comparePair == nil else { return }
                let visible = wanted != .detailOnly
                guard visible != sidebarVisible else { return }
                DispatchQueue.main.async { sidebarVisible = visible }
            }
        )
    }
    #endif

    /// Ładowanie jest stanem **wnętrza** okna, nie osobnym oknem.
    ///
    /// Wcześniej `body` podmieniał całą zawartość: dopóki biblioteka się
    /// wczytywała, oknem był sam `ProgressView`, a po wczytaniu wskakiwał na
    /// jego miejsce `NavigationSplitView` z inspektorem. Oba
    /// `SplitViewChildController` powstawały więc **wewnątrz okna, które już
    /// żyje**, a świeży `NSHostingView` zgłaszał wtedy swój pierwszy min/max
    /// rozmiar — to kolejkuje unieważnienie układu, a ono woła
    /// `setNeedsUpdateConstraints` na oknie będącym w środku własnego
    /// `updateConstraintsIfNeeded`.
    ///
    /// Przy szybkim wczytaniu ekran ładowania ledwo mignie i podmiana trafia
    /// w okno, które jeszcze nie stoi; przy dużej bibliotece kręciołek chodzi
    /// sekundami i sam napędza transakcje CoreAnimation. Lokalnie tego nie
    /// odtworzono — potwierdził tester, u którego 0.1.12 i 0.1.13 padały za
    /// każdym razem, a build z tą zmianą wstaje. Historia w DECYZJE.md,
    /// „Trzecia droga: podmiana całej zawartości okna".
    ///
    /// Trzymając podział kolumn zamontowany od pierwszej klatki, nie ma czego
    /// wstawiać do żywego okna — zmienia się tylko zawartość kolumny detalu.
    @ViewBuilder
    private func screen(_ mode: Mode) -> some View {
        if library.assets.isEmpty {
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loaded(mode)
        }
    }

    @ViewBuilder
    private func loaded(_ mode: Mode) -> some View {
        switch mode {
        case .grid:
            GridView(
                library: library,
                monitor: monitor,
                filters: filters,
                features: features,
                focus: focus,
                onOpen: { asset in
                    focus.id = asset.localIdentifier
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
                features: features, focus: focus
            )
        case .pair: PairView(library: library, similarity: similarity, focus: focus)
        }
    }

    /// Wejście do akcji na telefonie. Sam przycisk — cała zawartość mieszka
    /// w arkuszu, bo `Menu` na iOS zamyka się przy każdej przebudowie widoku,
    /// a tutaj przebudowa jest pewna: liczba serii i postęp liczenia zmieniają
    /// się w trakcie. Stąd brało się pulsowanie.
    @ViewBuilder
    private var actionsButton: some View {
        Button { showingActions = true } label: {
            // Kręciołek zamiast ikony, gdy coś mieli w tle — synchronizacja
            // automatyczna rusza sama przy starcie i bez tego wyglądała jak
            // zawieszenie aplikacji.
            if similarity.isWorking || sync.isWorking {
                ProgressView()
            } else {
                Image(systemName: "ellipsis.circle")
            }
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
            title: "load measures",
            icon: "camera.metering.spot",
            busy: importer.isWorking,
            help: importer.summary ?? "Reads sharpness, exposure and faces from the Photos library databases"
        ) {
            Task {
                await importer.run(context: context, library: library)
                await features.load(context: context)
                filters.adoptTerms(features.terms)
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
            title: "compute fingerprints",
            icon: "wand.and.stars",
            busy: similarity.isWorking,
            help: "Computes visual fingerprints for the whole library"
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

        if !filters.grades.isEmpty {
            let sorted = filters.grades.sorted { $0.rawValue < $1.rawValue }
            parts.append(sorted.map { grade -> String in
                if grade.isDeleted { return "to delete" }
                if grade.isUnrated { return "unrated" }
                return "★\(grade.rawValue)"
            }.joined(separator: ","))
        }

        let from = filters.fromYear, to = filters.toYear
        if from > 0 || to < 9999 {
            if from > 0 && to >= 9999 { parts.append("from \(String(from))") }
            else if from <= 0 { parts.append("to \(String(to))") }
            else { parts.append(from == to ? String(from) : "\(String(from))–\(String(to))") }
        }

        return parts.isEmpty ? "filter" : parts.joined(separator: " · ")
    }

    /// Synchronizacja jest ręczna i wsadowa. Zapis przez PhotoKit jest wolny,
    /// więc wołanie go po każdej ocenie zabiłoby tempo pracy.
    ///
    /// Dwa transporty obok siebie, bo robią co innego. **Albumy** pokazują
    /// gwiazdki w systemowych Zdjęciach — to jedyny sposób, żeby ocena była
    /// widoczna poza tą aplikacją. **Plik wymiany** przenosi całą resztę:
    /// dokładną wagę, liczbę ocen, odciski i stan turniejów.
    @ViewBuilder
    /// **Menu zostaje menu**, nawet w trakcie pracy — tylko ikona w środku
    /// zamienia się na kręciołek, w ramce tej samej wielkości.
    ///
    /// Wcześniej cały widok zamieniał się w gołego `ProgressView`, który ma
    /// inną szerokość niż pigułka z menu — reszta paska narzędzi przeskakiwała
    /// w bok na czas synchronizacji i wracała po jej końcu. Ten sam błąd,
    /// który `busyButton` naprawił gdzie indziej w tym pasku, ominął akurat
    /// to miejsce.
    fileprivate var syncControl: some View {
        let working = sync.isWorking
        return Menu {
            Button {
                Task {
                    await sync.synchronise(context: context, similarity: similarity, library: library)
                    // Tylko odczyt, już nie zapis. Gwiazdka jedzie teraz
                    // natywnie przez `PhotoLibrary.setRating`, na bieżąco,
                    // przy każdej realnej zmianie — patrz komentarz przy
                    // `AlbumSync`. `pull` zostaje jako jednorazowa siatka
                    // bezpieczeństwa na to, co ewentualnie leży w starych
                    // albumach z czasu, zanim `PHAsset.rating` istniało.
                    _ = albums.pull(into: context)
                }
            } label: {
                Label("sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!SyncFolder.isChosen)

            Divider()

            Button {
                chooseFolder()
            } label: {
                Label(
                    SyncFolder.isChosen ? "change shared folder…" : "choose shared folder…",
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
            ZStack {
                Image(systemName: "arrow.triangle.2.circlepath").opacity(working ? 0 : 1)
                if working { ProgressView().controlSize(.mini) }
            }
            .frame(width: 18, height: 16)
            .accessibilityLabel("sync")
        }
        .disabled(working)
        .help("sync")
        #if os(iOS)
        .fileImporter(
            isPresented: $choosingFolder, allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result { try? SyncFolder.remember(url) }
        }
        #endif
    }

    /// Folder wskazuje użytkownik, bo to jego iCloud Drive i jego dane —
    /// aplikacja nie ma prawa zakładać, gdzie mają leżeć.
    fileprivate func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Shared folder — ideally in iCloud Drive, so it travels between devices."
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

/// Jedno zadanie naraz: nowe odwołuje poprzednie. Zwykła klasa, żeby zmiana
/// zadania nie budziła widoku, który ją trzyma.
@MainActor
final class PendingTask {
    private var task: Task<Void, Never>?

    func replace(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { await work() }
    }
}

#if os(macOS)
/// Podgląd pokazuje zdjęcie spod wskaźnika miejsca, bo każde kliknięcie
/// w kafelek ustawia go razem z zaznaczeniem. Dzięki temu nie trzeba
/// osobno pamiętać, które z zaznaczonych jest „tym pierwszym".
///
/// Osobny widok, bo to on — a nie widok główny — ma śledzić wskaźnik:
/// strzałka przebudowuje wtedy podgląd, a nie całe okno.
private struct FocusedPreview: View {
    @ObservedObject var focus: Focus
    let library: PhotoLibrary
    let metadata: MetadataIndex
    let onFullScreen: () -> Void

    var body: some View {
        PreviewInspector(
            asset: focus.id.flatMap { library.asset(id: $0) },
            library: library,
            metadata: metadata,
            selectionCount: focus.selection.count,
            onFullScreen: onFullScreen
        )
    }
}
#endif
