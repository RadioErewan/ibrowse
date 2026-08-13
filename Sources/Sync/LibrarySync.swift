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

    /// Kolejność ma znaczenie i jest tu jedyną nieoczywistą rzeczą.
    ///
    /// Odciski muszą wejść **przed** przeliczeniem serii, a werdykty **po** —
    /// bo kluczem werdyktu jest skład serii, a ten powstaje dopiero przy
    /// przeliczeniu. Zastosowane w złej kolejności trafiłyby w grupy, których
    /// jeszcze nie ma, i cicho przepadły.
    func synchronise(context: ModelContext, similarity: Similarity) async {
        guard !isWorking else { return }
        guard let folder = SyncFolder.resolve() else {
            summary = "Wskaż najpierw folder wymiany."
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

        stage = "szukam plików…"
        let incoming = await Task.detached {
            Self.readOthers(in: source, excluding: mine, report: report)
        }.value

        var ratings = 0
        var prints = 0
        var verdicts = 0

        stage = "scalam oceny i odciski…"
        for payload in incoming {
            ratings += mergeRatings(payload.ratings, into: context)
            prints += mergePrints(payload.prints, into: context)
        }

        if prints > 0 {
            stage = "przeliczam serie…"
            // Nowe odciski unieważniają cache serii przez `SeriesStamp`,
            // więc to wywołanie faktycznie przelicza grupy, a nie tylko je
            // wczytuje.
            await similarity.loadGroups(context: context)
        }

        for payload in incoming {
            verdicts += mergeVerdicts(payload.verdicts, into: context)
        }

        try? context.save()

        do {
            stage = "zapisuję swój plik…"
            try await export(context: context, to: folder.url)
        } catch {
            summary = error.localizedDescription
            return
        }

        // Raport pokazuje **obie strony**, nie tylko przyrost. „Wczytano 0"
        // nie odróżnia „nie znalazłem pliku" od „znalazłem, ale wszystko już
        // mam" — a to są zupełnie różne sytuacje i tylko jedna jest błędem.
        if incoming.isEmpty {
            summary = "Nie znalazłem plików z innych urządzeń. Zapisałem swój."
        } else {
            let offered = incoming.reduce(into: (0, 0, 0)) { total, payload in
                total.0 += payload.ratings.count
                total.1 += payload.prints.count
                total.2 += payload.verdicts.count
            }
            let names = incoming.map(\.deviceName).joined(separator: ", ")
            let localPrints = ((try? context.fetch(FetchDescriptor<Fingerprint>())) ?? []).count

            summary = """
                Z \(incoming.count) pliku (\(names)): \(offered.0) ocen, \
                \(offered.1) odcisków, \(offered.2) serii.
                Nowe u mnie: \(ratings) ocen, \(prints) odcisków, \(verdicts) serii.
                Mam łącznie \(localPrints) odcisków.
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

        let others = contents
            .filter { $0.pathExtension == SyncFile.fileExtension && $0.lastPathComponent != mine }

        return others.enumerated()
            .compactMap { position, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                report(
                    "pobieram plik \(position + 1) z \(others.count)"
                    + (size > 0 ? " (\(size / 1_048_576) MB)" : "") + "…"
                )
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

    // MARK: - Scalanie

    private func mergeRatings(_ remote: [SyncFile.Rating], into context: ModelContext) -> Int {
        let local = ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
        var index = Dictionary(local.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = 0

        for entry in remote {
            if let existing = index[entry.assetID] {
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
                let fresh = Review(assetID: entry.assetID)
                fresh.weight = entry.weight
                fresh.isRated = entry.isRated
                fresh.judgements = entry.judgements
                fresh.markedForDeletion = entry.markedForDeletion
                fresh.updatedAt = entry.updatedAt
                context.insert(fresh)
                index[entry.assetID] = fresh
            }
            changed += 1
        }
        return changed
    }

    private func mergePrints(_ remote: [SyncFile.Print], into context: ModelContext) -> Int {
        let known = Set(((try? context.fetch(FetchDescriptor<Fingerprint>())) ?? [])
            .map(\.assetID))
        var added = 0

        for entry in remote where !known.contains(entry.assetID) {
            let fresh = Fingerprint(assetID: entry.assetID, values: [], takenAt: entry.takenAt)
            fresh.vector = entry.vector
            context.insert(fresh)
            added += 1
        }
        return added
    }

    private func mergeVerdicts(_ remote: [SyncFile.Verdict], into context: ModelContext) -> Int {
        let series = (try? context.fetch(FetchDescriptor<Series>())) ?? []
        let byKey = Dictionary(
            series.map { (SyncFile.key(for: $0.members), $0) }, uniquingKeysWith: { a, _ in a }
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
    private func export(context: ModelContext, to folder: URL) async throws {
        var payload = SyncFile.Payload()
        payload.deviceName = SyncFolder.deviceName

        payload.ratings = ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
            .filter { $0.isRated || $0.markedForDeletion }
            .map {
                SyncFile.Rating(
                    assetID: $0.assetID, weight: $0.weight, isRated: $0.isRated,
                    judgements: $0.judgements, markedForDeletion: $0.markedForDeletion,
                    updatedAt: $0.updatedAt
                )
            }

        payload.prints = ((try? context.fetch(FetchDescriptor<Fingerprint>())) ?? [])
            .map { SyncFile.Print(assetID: $0.assetID, vector: $0.vector, takenAt: $0.takenAt) }

        payload.verdicts = ((try? context.fetch(FetchDescriptor<Series>())) ?? [])
            .filter { $0.resolvedAt != nil || $0.challengerIndex > 1 }
            .map {
                SyncFile.Verdict(
                    key: SyncFile.key(for: $0.members), resolvedAt: $0.resolvedAt,
                    wasRejected: $0.wasRejected, championID: $0.championID,
                    challengerIndex: $0.challengerIndex
                )
            }

        // Zapis też poza głównym wątkiem — 50 MB przez SQLite to nie jest
        // czas, przez który okno ma stać.
        let destination = folder.appending(path: SyncFolder.fileName)
        let outgoing = payload
        try await Task.detached { try SyncFile.write(outgoing, to: destination) }.value
    }
}
