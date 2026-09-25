import Photos
import SwiftData
import SwiftUI

/// Scala pracę wykonaną na różnych urządzeniach.
///
/// Photos przenosi sam **gwiazdkę** (`PHAsset.rating`) i **oznaczenie do
/// skasowania** (album) — patrz `NativeSync`. Pliki wymiany niosą resztę:
/// dokładną wagę, liczbę ocen, stan turniejów, odciski i cechy.
///
/// Zasady scalania są różne dla każdego rodzaju danych, bo różnie się psują:
///
/// - **Cechy** to pomiar systemu, nie decyzja: bez straży czasu, pusty
///   pomiar nie nadpisuje niczego, wygrywa najnowszy plik.
///
/// - **Odciski** są deterministyczne — ten sam model Vision na tym samym
///   zdjęciu daje ten sam wektor. Więc dowolny jest równie dobry i bierzemy
///   po prostu brakujące. To największa oszczędność: telefon nie musi mielić
///   25 tysięcy zdjęć przez kilkanaście minut, skoro Mac już to zrobił.
/// - **Oceny** rozstrzygamy po czasie zapisu. To zwykłe „wygrywa nowszy",
///   ale świadome: nie ma tu historii zmian, więc wcześniejszej oceny nie da
///   się odzyskać, jeśli dwa urządzenia dotknęły tego samego zdjęcia.
/// - **Rozstrzygnięcia serii** kluczujemy składem grupy. Gdy skład się zmieni
///   — bo doszły zdjęcia albo przesunąłeś czułość — stary werdykt przestaje
///   pasować i seria wraca do kolejki. To jest poprawne zachowanie, nie strata.
@MainActor
final class LibrarySync: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var summary: String?

    /// Co się właśnie dzieje. Sam kręciołek nie mówi nic, a te etapy trwają
    /// zauważalnie: pobranie 50 MB z chmury, przeliczenie serii i zapis to
    /// trzy różne oczekiwania, których nie da się od siebie odróżnić bez nazwy.
    @Published private(set) var stage: String?

    /// Kiedy ostatnio przeczytaliśmy cudze pliki. Przeżywa zamknięcie
    /// aplikacji, bo to pytanie zadaje się po powrocie do komputera, a nie
    /// w trakcie jednej sesji.
    @Published private(set) var lastRead: Date? =
        UserDefaults.standard.object(forKey: "sync.lastRead") as? Date

    /// Najnowszy cudzy plik leżący w folderze wymiany, jeśli jest **nowszy**
    /// niż nasz ostatni odczyt.
    ///
    /// To jest odpowiedź na jedyne pytanie, którego ta aplikacja dotąd nie
    /// umiała zadać: „czy drugie urządzenie ma nowszą pracę". Synchronizacja
    /// jest ręczna po obu stronach, więc bez tego wygląda to jak utrata pracy
    /// — oceniasz na telefonie, siadasz do Maca i nie ma tam nic.
    ///
    /// Sprawdzenie jest **darmowe**: data pliku w chmurze jest w metadanych
    /// i nie wymaga ściągania zawartości.
    @Published private(set) var pending: Pending?

    struct Pending {
        let name: String
        let modified: Date
    }

    /// Rozgląda się po folderze bez czytania czegokolwiek.
    func refreshFolderState() async {
        guard let folder = SyncFolder.resolve() else { return }
        defer { folder.release() }

        // Własne pliki — patrz komentarz w `SyncFolder`.
        let mine = SyncFolder.ownFileNames
        let source = folder.url
        let seen = lastRead

        let found = await Task.detached { () -> Pending? in
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: source, includingPropertiesForKeys: keys
            )) ?? []

            var newest: Pending?
            for url in contents {
                let name = url.lastPathComponent
                // Także pliki jeszcze nieściągnięte — te mają kropkę z przodu
                // i cudze rozszerzenie. Patrz `readOthers`.
                let real = name.hasPrefix(".") && name.hasSuffix(".icloud")
                    ? String(name.dropFirst().dropLast(".icloud".count))
                    : name
                guard real.hasSuffix("." + SyncFile.fileExtension), !mine.contains(real) else { continue }
                guard let date = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { continue }
                if newest == nil || date > newest!.modified {
                    newest = Pending(name: String(real.dropLast(SyncFile.fileExtension.count + 1)),
                                     modified: date)
                }
            }
            guard let newest else { return nil }
            guard let seen else { return newest }
            return newest.modified > seen ? newest : nil
        }.value

        pending = found
    }

    private func noteRead() {
        let now = Date.now
        lastRead = now
        pending = nil
        UserDefaults.standard.set(now, forKey: "sync.lastRead")
    }

    // MARK: - Tryb automatyczny

    /// Cichy zapis własnych decyzji w toku — bez kręciołka w interfejsie,
    /// ale synchronizacja musi o nim wiedzieć, żeby obie nie pisały naraz.
    private var isWriting = false

    private static let fileDatesKey = "sync.fileDates"

    nonisolated private static var knownDates: [String: Date] {
        UserDefaults.standard.dictionary(forKey: fileDatesKey) as? [String: Date] ?? [:]
    }

    private static func remember(_ reads: [FileRead]) {
        var dates = knownDates
        for read in reads { dates[read.name] = read.modified }
        UserDefaults.standard.set(dates, forKey: fileDatesKey)
    }

    /// Mapowanie na identyfikatory chmurowe kosztuje zapytanie do systemu na
    /// 25 tysięcy zdjęć. Przy zapisie co kilkanaście sekund liczymy je raz na
    /// zestaw zdjęć, nie za każdym razem.
    private var cloudCache: (count: Int, map: [String: String])?

    private func cloudIDs(for library: PhotoLibrary) async -> [String: String] {
        if let cloudCache, cloudCache.count == library.assets.count { return cloudCache.map }
        // Poza wątkiem głównym: jedno zapytanie do PhotoKit o 25 tysięcy zdjęć
        // to sekundy, przez które okno stało zamrożone.
        let ids = library.assets.map(\.localIdentifier)
        let map = await Task.detached { CloudIdentity.cloudIDs(for: ids) }.value
        cloudCache = (library.assets.count, map)
        return map
    }

    /// Sprawdza daty cudzych plików (darmowe, bez pobierania) i czyta tylko
    /// zmienione. Wołane przy powrocie aplikacji na wierzch i co dwie minuty.
    func autoSync(context: ModelContext, similarity: Similarity, library: PhotoLibrary) async {
        guard !isWorking, !isWriting, !library.assets.isEmpty else { return }
        await refreshFolderState()
        guard pending != nil else { return }
        await synchronise(context: context, similarity: similarity, library: library, onlyChanged: true)
    }

    /// Zapisuje sam plik decyzji — mały, więc można to robić po każdej serii
    /// zmian. Bez raportu i bez kręciołka: to się dzieje w tle.
    func writeOwnDecisions(context: ModelContext, library: PhotoLibrary) async {
        guard !isWorking, !isWriting, !library.assets.isEmpty,
              let folder = SyncFolder.resolve() else { return }
        defer { folder.release() }
        isWriting = true
        defer { isWriting = false }
        let toCloud = await cloudIDs(for: library)
        let container = context.container
        let destination = folder.url
        try? await Task.detached(priority: .utility) {
            try Self.exportRatings(context: ModelContext(container), to: destination, translating: toCloud)
        }.value
    }

    /// Kolejność ma znaczenie i jest tu jedyną nieoczywistą rzeczą.
    ///
    /// Odciski muszą wejść **przed** przeliczeniem serii, a werdykty **po** —
    /// bo kluczem werdyktu jest skład serii, a ten powstaje dopiero przy
    /// przeliczeniu. Zastosowane w złej kolejności trafiłyby w grupy, których
    /// jeszcze nie ma, i cicho przepadły.
    /// `onlyChanged` — tryb automatyczny: czyta tylko pliki zmienione od
    /// ostatniego odczytu i pisze tylko własne decyzje. Ręczne „sync now"
    /// czyta i pisze wszystko, jako siatka bezpieczeństwa.
    func synchronise(
        context: ModelContext, similarity: Similarity, library: PhotoLibrary,
        onlyChanged: Bool = false
    ) async {
        guard !isWorking, !isWriting else { return }
        guard let folder = SyncFolder.resolve() else {
            summary = "Choose a shared folder first."
            return
        }
        defer { folder.release() }

        isWorking = true
        defer { isWorking = false; stage = nil }

        // Czytanie idzie poza główny wątek: plik z drugiego urządzenia potrafi
        // mieć 50 MB i przy pierwszym razie musi się dopiero ściągnąć z chmury.
        // Na głównym wątku zamroziłoby to okno na cały ten czas.
        let source = folder.url
        let mine = SyncFolder.ownFileNames
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.stage = text }
        }

        var clock = StageClock()
        stage = "looking for files…"
        let known = onlyChanged ? Self.knownDates : nil
        let reads = await Task.detached {
            Self.readOthers(in: source, excluding: mine, since: known, report: report)
        }.value
        let incoming = reads.map(\.payload)
        clock.mark("read")
        // Automatycznie i nic nowego: bez zapisu i bez nowego raportu.
        if onlyChanged && incoming.isEmpty {
            noteRead()
            return
        }

        // Identyfikatory w pliku są chmurowe i trzeba je przetłumaczyć na
        // lokalne **tego** urządzenia. Bez tego wpisy wyglądają jak dotyczące
        // nieznanych zdjęć i dokładają się obok istniejących, zamiast się
        // z nimi zejść.
        //
        // Jedno mapowanie na całą synchronizację, w obie strony. Odwrócenie
        // słownika jest darmowe, a drugie odpytanie systemu kosztowałoby tyle
        // samo co pierwsze — przy 25 tysiącach zdjęć to nie jest drobiazg.
        stage = "matching photos…"
        let toCloud = await cloudIDs(for: library)
        clock.mark("match")

        // Cała praca na bazie idzie na **osobnym kontekście w tle**. Na
        // głównym wątku, nawet z oddechem co 500 wierszy, scalanie stało
        // 15 sekund, a zapis z budową plików kolejne pięć bez przerwy —
        // kontekst z tysiącami niezapisanych zmian zwalnia każde kolejne
        // zapytanie. Główny kontekst widzi wynik po zapisie, jak każdą
        // zmianę w składzie.
        stage = "merging ratings and fingerprints…"
        let container = context.container
        let assets = library.assets
        let merged = await Task.detached(priority: .userInitiated) {
            Self.mergeIncoming(incoming, toCloud: toCloud, present: assets,
                               into: ModelContext(container))
        }.value
        clock.mark("merge")

        if merged.prints > 0 {
            stage = "recomputing bursts…"
            // Nowe odciski unieważniają cache serii przez `SeriesStamp`,
            // więc to wywołanie faktycznie przelicza grupy, a nie tylko je
            // wczytuje.
            await similarity.loadGroups(context: context)
            clock.mark("bursts")
        }

        // Werdykty **po** przeliczeniu serii — patrz komentarz nad funkcją.
        stage = "writing my file…"
        let destination = folder.url
        let finished = await Task.detached(priority: .userInitiated) {
            Self.finish(incoming, toCloud: toCloud, fullExport: !onlyChanged,
                        to: destination, context: ModelContext(container))
        }.value
        clock.mark("write")
        if let error = finished.error {
            summary = error.localizedDescription
            return
        }
        let ratings = merged.ratings
        let features = merged.features
        let prints = merged.prints
        let verdicts = finished.verdicts
        let orphans = merged.orphans
        Self.remember(reads)

        // Raport pokazuje **obie strony**, nie tylko przyrost. „Wczytano 0"
        // nie odróżnia „nie znalazłem pliku" od „znalazłem, ale wszystko już
        // mam" — a to są zupełnie różne sytuacje i tylko jedna jest błędem.
        if incoming.isEmpty {
            summary = "Found no files from other devices. Wrote mine."
            noteRead()
        } else {
            let offered = incoming.reduce(into: (0, 0, 0, 0)) { total, payload in
                // Bez wierszy ze starych plików, które niosły tylko cechy.
                total.0 += payload.ratings.filter { $0.isRated || $0.judgements > 0 }.count
                total.1 += payload.prints.count
                total.2 += payload.verdicts.count
                total.3 += payload.features.count
            }
            let names = incoming.map(\.deviceName).joined(separator: ", ")
            let localPrints = finished.localPrints

            noteRead()
            summary = """
                From \(incoming.count) \(incoming.count == 1 ? "file" : "files") (\(names)): \
                \(offered.0) ratings, \(offered.1) fingerprints, \(offered.2) bursts, \(offered.3) measures.
                Changed here: \(ratings) ratings, \(prints) fingerprints, \(verdicts) bursts, \
                \(features) photos' measures.
                \(localPrints) fingerprints in total\(orphans > 0 ? ", removed \(orphans) orphans" : "").
                """
        }
    }


    // MARK: - Pomiar

    /// Czas każdego etapu do logu systemowego (patrz `Trace`). Dzięki niemu
    /// wiadomo było, że okno zamrażało scalanie na głównym kontekście, a nie
    /// czytanie plików ani przeładowanie indeksu.
    struct StageClock {
        private var last = ContinuousClock.now

        mutating func mark(_ name: String) {
            let now = ContinuousClock.now
            let span = (now - last).components
            Trace.note("sync." + name, seconds: Double(span.seconds) + Double(span.attoseconds) / 1e18)
            last = now
        }
    }

    // MARK: - Czytanie

    /// Odczyt **skoordynowany**, a nie zwykły.
    ///
    /// Plik w chmurze bywa jeszcze nieściągnięty — istnieje wtedy tylko jako
    /// wpis w katalogu i zwykły odczyt zwróciłby pustkę. `NSFileCoordinator`
    /// każe dostawcy najpierw dostarczyć zawartość i czeka na nią.
    ///
    /// Świadomie zamiast `startDownloadingUbiquitousItem`, bo tamto działa
    /// wyłącznie z iCloud. Koordynator rozmawia z **dowolnym** dostawcą, więc
    /// folder wymiany może równie dobrze leżeć na Google Drive czy OneDrive.
    struct FileRead: Sendable {
        let payload: SyncFile.Payload
        let name: String
        let modified: Date
    }

    /// `since` — daty plików z ostatniego odczytu. Podane: czytamy **tylko
    /// pliki, które się od tamtej pory zmieniły**. Niezmienione były już
    /// scalone, a przy odciskach to 50 MB rozpakowywania za darmo.
    nonisolated private static func readOthers(
        in folder: URL, excluding mine: Set<String>, since known: [String: Date]?,
        report: @Sendable (String) -> Void
    ) -> [FileRead] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        // Data z wpisu w katalogu — także znacznika nieściągniętego pliku,
        // więc sprawdzenie niczego nie pobiera.
        var dates: [String: Date] = [:]

        // Plik **jeszcze nieściągnięty wygląda inaczej niż ściągnięty**.
        //
        // iCloud Drive pokazuje go jako znacznik zastępczy o nazwie
        // `.nazwa.ibsync.icloud` — z kropką z przodu i cudzym rozszerzeniem.
        // Filtr po samym `ibsync` przelatywał obok, więc telefon, który nigdy
        // nie pobrał 58 MB z Maca, meldował „nie znalazłem plików" stojąc
        // dokładnie nad tym plikiem. Na Macu problem nie występował, bo tam
        // wszystko było od dawna na dysku.
        //
        // Ze znacznika odtwarzamy prawdziwą nazwę i dalej pracujemy na niej —
        // koordynator odczytu i tak każe dostawcy dostarczyć zawartość.
        let placeholder = ".icloud"
        let others = contents
            .compactMap { url -> URL? in
                let name = url.lastPathComponent
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if url.pathExtension == SyncFile.fileExtension {
                    dates[name] = modified
                    return url
                }
                guard name.hasPrefix("."), name.hasSuffix(placeholder) else { return nil }
                let real = String(name.dropFirst().dropLast(placeholder.count))
                guard real.hasSuffix("." + SyncFile.fileExtension) else { return nil }
                dates[real] = modified
                return folder.appending(path: real)
            }
            .filter { !mine.contains($0.lastPathComponent) }
            .filter { url in
                guard let known else { return true }
                let name = url.lastPathComponent
                return (dates[name] ?? .distantPast) > (known[name] ?? .distantPast)
            }

        return others.enumerated()
            .compactMap { position, url in
                // „czytam", nie „pobieram": pobranie to co najwyżej pierwszy
                // raz, a rozpakowanie 50 MB odcisków trwa za każdym. Etykieta
                // sugerująca sieć kazała szukać winy w chmurze, gdy plik od
                // dawna leżał na dysku.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let onDisk = FileManager.default.fileExists(atPath: url.path)
                report(
                    (onDisk ? "reading" : "downloading") + " file \(position + 1) of \(others.count)"
                    + (size > 0 ? " (\(size / 1_048_576) MB)" : "") + "…"
                )

                // Prośba wprost, gdy pliku fizycznie nie ma. Koordynator zwykle
                // sam każe go dostarczyć, ale przy pierwszym pobraniu dziesiątek
                // megabajtów potrafi odpowiedzieć szybciej, niż dostawca zdąży —
                // a wtedy odczyt zwraca pustkę zamiast czekać.
                if !onDisk {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
                var payload: SyncFile.Payload?
                var failure: NSError?
                NSFileCoordinator().coordinate(
                    readingItemAt: url, options: [], error: &failure
                ) { readable in
                    payload = SyncFile.read(readable)
                }
                guard let payload else { return nil }
                let name = url.lastPathComponent
                return FileRead(payload: payload, name: name, modified: dates[name] ?? .now)
            }
    }

    /// Usuwa odciski i serie wskazujące na zdjęcia, których w bibliotece nie ma.
    ///
    /// Powstają na dwa sposoby. Zwyczajnie — gdy skasujesz zdjęcie, a wpis po
    /// nim zostaje. I nadzwyczajnie: pierwsza wersja synchronizacji wciągnęła
    /// identyfikatory z drugiego urządzenia, które tutaj nie znaczą nic. Bez
    /// sprzątania takie serie trafiają do parowania i pokazują pustkę.
    nonisolated private static func discardOrphans(context: ModelContext, present: [PHAsset]) -> Int {
        let known = Set(present.map(\.localIdentifier))
        guard !known.isEmpty else { return 0 }
        var removed = 0

        for print in (try? context.fetch(FetchDescriptor<Fingerprint>())) ?? []
        where !known.contains(print.assetID) {
            context.delete(print)
            removed += 1
        }

        // Serię kasujemy, gdy **którykolwiek** członek zniknął: jej skład był
        // podstawą porównania i niepełna grupa to już inna grupa.
        for series in (try? context.fetch(FetchDescriptor<Series>())) ?? []
        where !series.members.allSatisfy(known.contains) {
            context.delete(series)
        }

        return removed
    }

    /// Klucz serii liczony z identyfikatorów chmurowych. `nil`, gdy choć
    /// jedno zdjęcie nie ma odpowiednika — niepełny skład to inna grupa
    /// i lepiej jej nie dopasowywać, niż dopasować błędnie.
    nonisolated private static func cloudKey(for members: [String], using toCloud: [String: String]) -> String? {
        let translated = members.compactMap { toCloud[$0] }
        guard translated.count == members.count else { return nil }
        return SyncFile.key(for: translated)
    }


    // MARK: - Scalanie

    struct Merged {
        var ratings = 0
        /// Zdjęcia, których cechy się faktycznie zmieniły — te same cechy
        /// przychodzą z kilku plików naraz.
        var features = 0
        var prints = 0
        var orphans = 0
    }

    /// Pierwsza połowa synchronizacji, **na kontekście w tle**: sprzątanie,
    /// oceny, cechy i odciski, jeden zapis na końcu.
    nonisolated private static func mergeIncoming(
        _ incoming: [SyncFile.Payload], toCloud: [String: String], present: [PHAsset],
        into context: ModelContext
    ) -> Merged {
        context.autosaveEnabled = false
        var result = Merged()
        result.orphans = discardOrphans(context: context, present: present)

        var toLocal: [String: String] = [:]
        toLocal.reserveCapacity(toCloud.count)
        for (local, cloud) in toCloud { toLocal[cloud] = local }

        var features = Set<String>()
        // Od najstarszego pliku do najnowszego: przy cechach wygrywa ostatni
        // zastosowany, a to ma być pomiar najświeższy.
        for payload in incoming.sorted(by: { $0.writtenAt < $1.writtenAt }) {
            result.ratings += mergeRatings(payload.ratings, translating: toLocal, into: context)
            features.formUnion(mergeFeatures(payload.features, translating: toLocal, into: context))
            result.prints += mergePrints(payload.prints, translating: toLocal, into: context)
        }
        result.features = features.count

        // Tylko przy prawdziwych zmianach — pusty zapis też budziłby zapis pliku.
        if context.hasChanges { try? context.save() }
        return result
    }

    struct Finished {
        var verdicts = 0
        var localPrints = 0
        var error: Error?
    }

    /// Druga połowa, też w tle: werdykty (po przeliczeniu serii) i własne pliki.
    nonisolated private static func finish(
        _ incoming: [SyncFile.Payload], toCloud: [String: String], fullExport: Bool,
        to folder: URL, context: ModelContext
    ) -> Finished {
        context.autosaveEnabled = false
        var result = Finished()
        for payload in incoming {
            result.verdicts += mergeVerdicts(payload.verdicts, translating: toCloud, into: context)
        }
        if context.hasChanges { try? context.save() }

        do {
            if fullExport {
                try export(context: context, to: folder, translating: toCloud)
            } else {
                // Odcisków i cech nie odsyłamy w trybie automatycznym — przyrost
                // z cudzego pliku przepisałby nasz 50 MB tylko po to, żeby
                // drugie urządzenie dostało z powrotem własne dane.
                try exportRatings(context: context, to: folder, translating: toCloud)
            }
        } catch {
            result.error = error
        }
        result.localPrints = (try? context.fetchCount(FetchDescriptor<Fingerprint>())) ?? 0
        return result
    }

    nonisolated private static func mergeRatings(
        _ remote: [SyncFile.Rating], translating toLocal: [String: String],
        into context: ModelContext
    ) -> Int {
        let local = ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
        var index = Dictionary(local.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = 0

        for entry in remote {
            // Wiersze ze starych plików, które istniały tylko po to, żeby nieść
            // cechy (nigdy nieocenione). Cechy wyjął już odczyt; decyzji tu nie ma.
            guard entry.isRated || entry.judgements > 0 else { continue }
            // Brak tłumaczenia znaczy, że tego zdjęcia tu nie ma — nie jest to
            // błąd, tylko inny stan biblioteki. Pomijamy w ciszy.
            guard let assetID = toLocal[entry.assetID] else { continue }

            // Oznaczenia do skasowania **nie** jadą tą drogą — tylko albumem
            // w Photos. Plik „wygrywa nowszy" potrafiłby oznaczyć z powrotem
            // zdjęcie wyjęte z albumu, bo odczyt z Photos nie rusza `updatedAt`.
            if let existing = index[assetID] {
                guard entry.updatedAt > existing.updatedAt else { continue }
                // Przypisujemy wprost, a nie przez `set()`: tamto podbiłoby
                // licznik ocen i datę, czyli policzyłoby przepisanie cudzej
                // decyzji jako własną.
                existing.weight = entry.weight
                existing.isRated = entry.isRated
                existing.judgements = max(existing.judgements, entry.judgements)
                existing.updatedAt = entry.updatedAt
            } else {
                let fresh = Review(assetID: assetID)
                fresh.weight = entry.weight
                fresh.isRated = entry.isRated
                fresh.judgements = entry.judgements
                fresh.updatedAt = entry.updatedAt
                context.insert(fresh)
                index[assetID] = fresh
            }
            changed += 1
        }
        return changed
    }

    /// Cechy to pomiar systemu, nie decyzja — **bez straży czasu**. Pusty
    /// pomiar nie nadpisuje niczego (zero znaczy „nie policzono"), a przy kilku
    /// plikach wygrywa ostatni zastosowany, czyli najnowszy — patrz kolejność
    /// w `synchronise`. Od kiedy cechy mają własny plik, nie mieszają się
    /// z oceną i nie potrzebują dawnego wyjątku od reguły „wygrywa nowszy".
    /// Zwraca zdjęcia, w których coś się **faktycznie zmieniło** — przepisanie
    /// tej samej wartości z kolejnego pliku to nie nowość, a raport ma mówić
    /// prawdę.
    nonisolated private static func mergeFeatures(
        _ remote: [SyncFile.Features], translating toLocal: [String: String],
        into context: ModelContext
    ) -> Set<String> {
        guard !remote.isEmpty else { return [] }
        let local = ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
        var index = Dictionary(local.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = Set<String>()

        for entry in remote where entry.carriesAnything {
            guard let assetID = toLocal[entry.assetID] else { continue }
            let review = index[assetID] ?? {
                // Rekord tylko pod cechy nie jest decyzją: `.distantPast`, żeby
                // przy scalaniu ocen nie udawał nowszego od prawdziwej oceny.
                let fresh = Review(assetID: assetID)
                fresh.updatedAt = .distantPast
                context.insert(fresh)
                index[assetID] = fresh
                return fresh
            }()
            // Przypisujemy **tylko różnice**. Przepisanie tej samej wartości też
            // brudzi rekord: zapis niósł wtedy całą bibliotekę, a główny
            // kontekst wciągał ją potem na głównym wątku.
            let before = (review.sharpness, review.exposure, review.faces, review.eyesClosed,
                          review.smiles, review.isScreenshot)
            let incoming = (entry.sharpness, entry.exposure, entry.faces, entry.eyesClosed,
                            entry.smiles, entry.isScreenshot)
            var touched = false
            if entry.sharpness > 0 || entry.exposure > 0 || entry.faces > 0 || entry.isScreenshot,
               before != incoming {
                review.sharpness = entry.sharpness
                review.exposure = entry.exposure
                review.faces = entry.faces
                review.eyesClosed = entry.eyesClosed
                review.smiles = entry.smiles
                review.isScreenshot = entry.isScreenshot
                touched = true
            }
            if !entry.measures.isEmpty, review.measures != entry.measures {
                review.measures = entry.measures
                touched = true
            }
            if !entry.terms.isEmpty, review.searchTerms != entry.terms {
                review.searchTerms = entry.terms
                touched = true
            }
            if !entry.panel.isEmpty, review.panel != entry.panel {
                review.panel = entry.panel
                touched = true
            }
            if touched { changed.insert(assetID) }
        }
        return changed
    }

    nonisolated private static func mergePrints(
        _ remote: [SyncFile.Print], translating toLocal: [String: String],
        into context: ModelContext
    ) -> Int {
        let known = Set(((try? context.fetch(FetchDescriptor<Fingerprint>())) ?? [])
            .map(\.assetID))
        var added = 0

        for entry in remote {
            guard let assetID = toLocal[entry.assetID], !known.contains(assetID) else { continue }
            let fresh = Fingerprint(assetID: assetID, values: [], takenAt: entry.takenAt)
            fresh.vector = entry.vector
            context.insert(fresh)
            added += 1
        }
        return added
    }

    /// Werdykty też muszą przejść przez identyfikatory chmurowe.
    ///
    /// Kluczem werdyktu jest skład serii, a skład to identyfikatory zdjęć —
    /// czyli dokładnie ta rzecz, która różni się między urządzeniami. Klucz
    /// liczony z identyfikatorów lokalnych nigdy nie trafiłby w cudzy.
    nonisolated private static func mergeVerdicts(
        _ remote: [SyncFile.Verdict], translating toCloud: [String: String],
        into context: ModelContext
    ) -> Int {
        let series = (try? context.fetch(FetchDescriptor<Series>())) ?? []
        let byKey = Dictionary(
            series.compactMap { item -> (String, Series)? in
                guard let key = Self.cloudKey(for: item.members, using: toCloud) else { return nil }
                return (key, item)
            },
            uniquingKeysWith: { a, _ in a }
        )
        var applied = 0

        for entry in remote {
            guard let local = byKey[entry.key] else { continue }

            // Rozstrzygnięta wygrywa z nierozstrzygniętą, a przy dwóch
            // rozstrzygniętych — nowsza. Postęp niedokończonego turnieju
            // przenosimy tylko wtedy, gdy lokalnie nikt go jeszcze nie zaczął.
            if let remoteAt = entry.resolvedAt {
                if local.resolvedAt == nil || local.resolvedAt! < remoteAt {
                    local.resolvedAt = remoteAt
                    local.wasRejected = entry.wasRejected
                    local.championID = entry.championID
                    local.challengerIndex = entry.challengerIndex
                    applied += 1
                }
            } else if local.resolvedAt == nil,
                      local.challengerIndex <= 1,
                      entry.challengerIndex > 1 {
                local.championID = entry.championID
                local.challengerIndex = entry.challengerIndex
                applied += 1
            }
        }
        return applied
    }

    // MARK: - Zapis

    /// **Dwa pliki, dwa tempa.** Decyzje wypisujemy zawsze — lekkie,
    /// zmieniają się przy każdej sesji. Odciski **tylko wtedy, gdy się
    /// zmieniły** (albo zniknęły z folderu) — patrz `exportFingerprints`.
    /// Telefon nie płaci pełnej ceny 50 MB za każdą sesję oceniania, tylko
    /// kilka kilobajtów decyzji. Trzeci plik, cechy, pisze wyłącznie eksporter.
    nonisolated private static func export(
        context: ModelContext, to folder: URL, translating toCloud: [String: String]
    ) throws {
        try exportRatings(context: context, to: folder, translating: toCloud)
        try exportFingerprints(context: context, to: folder, translating: toCloud)
    }


    nonisolated private static func exportRatings(
        context: ModelContext, to folder: URL, translating toCloud: [String: String]
    ) throws {
        var payload = SyncFile.Payload()
        payload.deviceName = SyncFolder.deviceName

        // Same decyzje. Cechy mają własny plik, oznaczenia jadą albumem.
        let reviews = ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
            .filter { $0.isRated || $0.judgements > 0 }

        payload.ratings = reviews.compactMap { review in
            guard let cloud = toCloud[review.assetID] else { return nil }
            return SyncFile.Rating(
                assetID: cloud, weight: review.weight, isRated: review.isRated,
                judgements: review.judgements, updatedAt: review.updatedAt
            )
        }

        payload.verdicts = ((try? context.fetch(FetchDescriptor<Series>())) ?? [])
            .filter { $0.resolvedAt != nil || $0.challengerIndex > 1 }
            .compactMap { item in
                guard let key = Self.cloudKey(for: item.members, using: toCloud) else { return nil }
                return SyncFile.Verdict(
                    key: key, resolvedAt: item.resolvedAt, wasRejected: item.wasRejected,
                    championID: item.championID.flatMap { toCloud[$0] },
                    challengerIndex: item.challengerIndex
                )
            }

        // Ta sama treść co ostatnio — nie piszemy. Bez tego odczyt cudzego
        // pliku zapisywał bazę, zapis bazy wypisywał nasz plik, a drugie
        // urządzenie brało go za nowość: dwa urządzenia przerzucałyby się tym
        // samym plikiem co kilka minut, bez końca.
        let digest = Self.digest(of: payload)
        let defaults = UserDefaults.standard
        if digest == defaults.string(forKey: Self.ratingsDigestKey),
           SyncFolder.contains(SyncFolder.ratingsFileName, in: folder) { return }

        let destination = folder.appending(path: SyncFolder.ratingsFileName)
        let outgoing = payload
        try SyncFile.write(outgoing, to: destination)
        defaults.set(digest, forKey: Self.ratingsDigestKey)
    }

    private static let ratingsDigestKey = "sync.ratingsDigest"

    /// Skrót treści decyzji, niezależny od kolejności wierszy. `Hasher` się nie
    /// nadaje — jego ziarno zmienia się przy każdym uruchomieniu.
    nonisolated private static func digest(of payload: SyncFile.Payload) -> String {
        let ratings = payload.ratings
            .map { "\($0.assetID)|\($0.weight)|\($0.isRated)|\($0.judgements)|\($0.updatedAt.timeIntervalSince1970)" }
            .sorted()
        let verdicts = payload.verdicts
            .map { "\($0.key)|\($0.resolvedAt?.timeIntervalSince1970 ?? -1)|\($0.wasRejected)|\($0.championID ?? "")|\($0.challengerIndex)" }
            .sorted()
        return SyncFile.key(for: ratings + ["--"] + verdicts)
    }

    /// Klucz w `UserDefaults`, pod którym pamiętamy, ile odcisków niósł
    /// ostatni **zapisany** plik.
    private static let lastFingerprintCountKey = "sync.lastFingerprintCount"

    /// Przepisuje plik odcisków **tylko wtedy, gdy ich liczba się zmieniła**
    /// od ostatniego zapisu.
    ///
    /// Odciski są deterministyczne — ten sam model Vision na tym samym
    /// zdjęciu daje ten sam wektor, więc raz zapisany wektor nigdy się nie
    /// zmienia. Jedyne, co się zmienia, to **które** zdjęcia mają odcisk,
    /// a to rośnie tylko wtedy, gdy jawnie każesz je policzyć — rzadka,
    /// świadoma operacja, nie coś, co dzieje się przy zwykłym ocenianiu.
    ///
    /// Licznik, nie skrót kryptograficzny — prostsze, tańsze i wystarczające:
    /// jedyny sposób, w jaki liczba mogłaby zostać ta sama przy innej
    /// zawartości, to usunięcie jednego zdjęcia i dodanie innego tego samego
    /// dnia synchronizacji, co jest rzadkie i naprawia się samo przy
    /// następnej zmianie liczby.
    nonisolated private static func exportFingerprints(
        context: ModelContext, to folder: URL, translating toCloud: [String: String]
    ) throws {
        let fingerprints = (try? context.fetch(FetchDescriptor<Fingerprint>())) ?? []
        let defaults = UserDefaults.standard
        guard fingerprints.count != defaults.integer(forKey: Self.lastFingerprintCountKey)
                || !SyncFolder.contains(SyncFolder.fingerprintsFileName, in: folder) else {
            return
        }

        var payload = SyncFile.Payload()
        payload.deviceName = SyncFolder.deviceName
        payload.prints = fingerprints.compactMap { print in
            guard let cloud = toCloud[print.assetID] else { return nil }
            return SyncFile.Print(assetID: cloud, vector: print.vector, takenAt: print.takenAt)
        }

        let destination = folder.appending(path: SyncFolder.fingerprintsFileName)
        let outgoing = payload
        // Zapis poza głównym wątkiem — 50 MB przez SQLite to nie jest czas,
        // przez który okno ma stać.
        try SyncFile.write(outgoing, to: destination)
        defaults.set(fingerprints.count, forKey: Self.lastFingerprintCountKey)
    }
}
