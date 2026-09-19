import Photos
import SwiftData
import SwiftUI

/// Scala pracę wykonaną na różnych urządzeniach.
///
/// Albumy Photos przenoszą **gwiazdkę** i są widoczne w systemowych Zdjęciach,
/// ale gubią wszystko, co czyni to narzędzie użytecznym: dokładną wagę, liczbę
/// ocen, odciski wizualne i stan turniejów. Plik wymiany przenosi całość.
///
/// Zasady scalania są różne dla każdego rodzaju danych, bo różnie się psują:
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

        let mine = SyncFolder.fileName
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
                guard real.hasSuffix("." + SyncFile.fileExtension), real != mine else { continue }
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

    /// Kolejność ma znaczenie i jest tu jedyną nieoczywistą rzeczą.
    ///
    /// Odciski muszą wejść **przed** przeliczeniem serii, a werdykty **po** —
    /// bo kluczem werdyktu jest skład serii, a ten powstaje dopiero przy
    /// przeliczeniu. Zastosowane w złej kolejności trafiłyby w grupy, których
    /// jeszcze nie ma, i cicho przepadły.
    func synchronise(
        context: ModelContext, similarity: Similarity, library: PhotoLibrary
    ) async {
        guard !isWorking else { return }
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
        let mine = SyncFolder.fileName
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.stage = text }
        }

        stage = "cleaning up orphans…"
        let orphans = discardOrphans(context: context, library: library)

        stage = "looking for files…"
        let incoming = await Task.detached {
            Self.readOthers(in: source, excluding: mine, report: report)
        }.value

        var ratings = 0
        var prints = 0
        var verdicts = 0

        // Identyfikatory w pliku są chmurowe i trzeba je przetłumaczyć na
        // lokalne **tego** urządzenia. Bez tego wpisy wyglądają jak dotyczące
        // nieznanych zdjęć i dokładają się obok istniejących, zamiast się
        // z nimi zejść.
        //
        // Jedno mapowanie na całą synchronizację, w obie strony. Odwrócenie
        // słownika jest darmowe, a drugie odpytanie systemu kosztowałoby tyle
        // samo co pierwsze — przy 25 tysiącach zdjęć to nie jest drobiazg.
        stage = "matching photos…"
        let toCloud = CloudIdentity.cloudIDs(for: library.assets.map(\.localIdentifier))
        var toLocal: [String: String] = [:]
        toLocal.reserveCapacity(toCloud.count)
        for (local, cloud) in toCloud { toLocal[cloud] = local }

        stage = "merging ratings and fingerprints…"
        for payload in incoming {
            ratings += mergeRatings(payload.ratings, translating: toLocal, into: context)
            prints += mergePrints(payload.prints, translating: toLocal, into: context)
        }

        if prints > 0 {
            stage = "recomputing bursts…"
            // Nowe odciski unieważniają cache serii przez `SeriesStamp`,
            // więc to wywołanie faktycznie przelicza grupy, a nie tylko je
            // wczytuje.
            await similarity.loadGroups(context: context)
        }

        for payload in incoming {
            verdicts += mergeVerdicts(payload.verdicts, translating: toCloud, into: context)
        }

        try? context.save()

        do {
            stage = "writing my file…"
            try await export(context: context, to: folder.url, translating: toCloud)
        } catch {
            summary = error.localizedDescription
            return
        }

        // Raport pokazuje **obie strony**, nie tylko przyrost. „Wczytano 0"
        // nie odróżnia „nie znalazłem pliku" od „znalazłem, ale wszystko już
        // mam" — a to są zupełnie różne sytuacje i tylko jedna jest błędem.
        if incoming.isEmpty {
            summary = "Found no files from other devices. Wrote mine."
            noteRead()
        } else {
            let offered = incoming.reduce(into: (0, 0, 0)) { total, payload in
                total.0 += payload.ratings.count
                total.1 += payload.prints.count
                total.2 += payload.verdicts.count
            }
            let names = incoming.map(\.deviceName).joined(separator: ", ")
            let localPrints = ((try? context.fetch(FetchDescriptor<Fingerprint>())) ?? []).count

            noteRead()
            summary = """
                Z \(incoming.count) pliku (\(names)): \(offered.0) ocen, \
                \(offered.1) odcisków, \(offered.2) serii.
                Nowe u mnie: \(ratings) ocen, \(prints) odcisków, \(verdicts) serii.
                Mam łącznie \(localPrints) odcisków\(orphans > 0 ? ", removed \(orphans) orphans" : "").
                """
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
    nonisolated private static func readOthers(
        in folder: URL, excluding mine: String, report: @Sendable (String) -> Void
    ) -> [SyncFile.Payload] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []

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
                if url.pathExtension == SyncFile.fileExtension { return url }
                guard name.hasPrefix("."), name.hasSuffix(placeholder) else { return nil }
                let real = String(name.dropFirst().dropLast(placeholder.count))
                guard real.hasSuffix("." + SyncFile.fileExtension) else { return nil }
                return folder.appending(path: real)
            }
            .filter { $0.lastPathComponent != mine }

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
                return payload
            }
    }

    /// Usuwa odciski i serie wskazujące na zdjęcia, których w bibliotece nie ma.
    ///
    /// Powstają na dwa sposoby. Zwyczajnie — gdy skasujesz zdjęcie, a wpis po
    /// nim zostaje. I nadzwyczajnie: pierwsza wersja synchronizacji wciągnęła
    /// identyfikatory z drugiego urządzenia, które tutaj nie znaczą nic. Bez
    /// sprzątania takie serie trafiają do parowania i pokazują pustkę.
    private func discardOrphans(context: ModelContext, library: PhotoLibrary) -> Int {
        let known = Set(library.assets.map(\.localIdentifier))
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

        if removed > 0 { try? context.save() }
        return removed
    }

    /// Klucz serii liczony z identyfikatorów chmurowych. `nil`, gdy choć
    /// jedno zdjęcie nie ma odpowiednika — niepełny skład to inna grupa
    /// i lepiej jej nie dopasowywać, niż dopasować błędnie.
    private static func cloudKey(for members: [String], using toCloud: [String: String]) -> String? {
        let translated = members.compactMap { toCloud[$0] }
        guard translated.count == members.count else { return nil }
        return SyncFile.key(for: translated)
    }

    // MARK: - Scalanie

    private func mergeRatings(
        _ remote: [SyncFile.Rating], translating toLocal: [String: String],
        into context: ModelContext
    ) -> Int {
        let local = ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
        var index = Dictionary(local.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = 0

        for entry in remote {
            // Brak tłumaczenia znaczy, że tego zdjęcia tu nie ma — nie jest to
            // błąd, tylko inny stan biblioteki. Pomijamy w ciszy.
            guard let assetID = toLocal[entry.assetID] else { continue }

            if let existing = index[assetID] {
                // Cechy **przed** strażą czasu i niezależnie od niej.
                //
                // To pomiar systemu, nie decyzja, więc nie ma czego rozstrzygać
                // po czasie. Gdyby jechały razem z oceną, Mac wysyłałby tysiące
                // pustych ocen ze świeżą datą, a każda taka — będąc nowszą —
                // skasowałaby ocenę postawioną wcześniej na telefonie. Zamiast
                // tego obowiązuje „kto ma, ten daje": pusty pomiar nie nadpisuje
                // niczego, a niepusty uzupełnia brak.
                if !entry.measures.isEmpty {
                    existing.measures = entry.measures
                }
                if entry.sharpness > 0 || entry.exposure > 0
                    || entry.faces > 0 || entry.isScreenshot {
                    existing.sharpness = entry.sharpness
                    existing.exposure = entry.exposure
                    existing.faces = entry.faces
                    existing.eyesClosed = entry.eyesClosed
                    existing.smiles = entry.smiles
                    existing.isScreenshot = entry.isScreenshot
                }

                guard entry.updatedAt > existing.updatedAt else { continue }
                // Przypisujemy wprost, a nie przez `set()`: tamto podbiłoby
                // licznik ocen i datę, czyli policzyłoby przepisanie cudzej
                // decyzji jako własną.
                existing.weight = entry.weight
                existing.isRated = entry.isRated
                existing.judgements = max(existing.judgements, entry.judgements)
                existing.markedForDeletion = entry.markedForDeletion
                existing.updatedAt = entry.updatedAt
            } else {
                let fresh = Review(assetID: assetID)
                fresh.weight = entry.weight
                fresh.isRated = entry.isRated
                fresh.judgements = entry.judgements
                fresh.markedForDeletion = entry.markedForDeletion
                fresh.updatedAt = entry.updatedAt
                fresh.sharpness = entry.sharpness
                fresh.exposure = entry.exposure
                fresh.faces = entry.faces
                fresh.eyesClosed = entry.eyesClosed
                fresh.smiles = entry.smiles
                fresh.isScreenshot = entry.isScreenshot
                fresh.measures = entry.measures
                context.insert(fresh)
                index[assetID] = fresh
            }
            changed += 1
        }
        return changed
    }

    private func mergePrints(
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
    private func mergeVerdicts(
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

    /// Wypisujemy **cały** stan, nie różnicę. Plik jest jedyną prawdą o tym
    /// urządzeniu i musi dać się przeczytać w oderwaniu od historii — inaczej
    /// zgubienie jednego przyrostu psułoby wszystkie następne. Odciski to
    /// około 39 MB przy 25 tysiącach zdjęć; zapis trwa moment, a upraszcza
    /// całą resztę.
    private func export(
        context: ModelContext, to folder: URL, translating toCloud: [String: String]
    ) async throws {
        var payload = SyncFile.Payload()
        payload.deviceName = SyncFolder.deviceName

        // Także rekordy bez oceny, o ile niosą cechy — to jest cały sens ich
        // istnienia. Filtr przepuszczający wyłącznie ocenione zostawiłby
        // pomiary systemu na Macu, a telefon nie ma jak policzyć ich sam.
        let reviews = ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
            .filter { $0.isRated || $0.markedForDeletion || $0.hasFeatures }
        let fingerprints = (try? context.fetch(FetchDescriptor<Fingerprint>())) ?? []

        // Jedno tłumaczenie na cały zapis. Wpisy bez odpowiednika w chmurze
        // pomijamy — dotyczą zdjęć, których inne urządzenia i tak nie znajdą.
        payload.ratings = reviews.compactMap { review in
            guard let cloud = toCloud[review.assetID] else { return nil }
            return SyncFile.Rating(
                assetID: cloud, weight: review.weight, isRated: review.isRated,
                judgements: review.judgements, markedForDeletion: review.markedForDeletion,
                updatedAt: review.updatedAt,
                sharpness: review.sharpness, exposure: review.exposure,
                faces: review.faces, eyesClosed: review.eyesClosed,
                smiles: review.smiles, isScreenshot: review.isScreenshot,
                measures: review.measures
            )
        }

        payload.prints = fingerprints.compactMap { print in
            guard let cloud = toCloud[print.assetID] else { return nil }
            return SyncFile.Print(assetID: cloud, vector: print.vector, takenAt: print.takenAt)
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

        // Zapis też poza głównym wątkiem — 50 MB przez SQLite to nie jest
        // czas, przez który okno ma stać.
        let destination = folder.appending(path: SyncFolder.fileName)
        let outgoing = payload
        try await Task.detached { try SyncFile.write(outgoing, to: destination) }.value
    }
}
