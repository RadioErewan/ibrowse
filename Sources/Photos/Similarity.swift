import Photos
import SwiftData
import SwiftUI
import Vision

/// Liczy odciski wizualne i składa z nich grupy serii.
///
/// Używa `VNGenerateImageFeaturePrintRequest` — natywnego Vision, liczonego
/// na urządzeniu. Żadnego modelu do pobrania, ta sama ścieżka na macOS i iOS.
@MainActor
final class Similarity: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var progress = 0
    @Published private(set) var total = 0
    @Published private(set) var groups: [[String]] = []
    @Published private(set) var seriesIDs: [PersistentIdentifier] = []
    @Published private(set) var isGrouping = false

    /// Wynik ostatniego liczenia, pokazywany przez chwilę po zakończeniu.
    @Published private(set) var note: String?
    private var noteTimer: Task<Void, Never>?

    /// Zdjęcia dalej od siebie w czasie niż to okno nigdy nie trafią do
    /// jednej grupy — nawet jeśli wyglądają identycznie. Las z 2014 podobny
    /// do lasu z 2023 to nie jest seria i nie chcesz ich zestawiać.
    private let timeWindow: TimeInterval = 5 * 60

    /// Próg odległości deskryptorów, regulowany z interfejsu. Im wyżej,
    /// tym chętniej zdjęcia lądują w jednej serii.
    @Published var threshold: Float = 0.42

    /// Zdjęcia wyzwolone tak szybko po sobie należą do jednej serii
    /// **niezależnie od tego, co widać na kadrze**.
    ///
    /// Seria startów F-16 to kilkanaście klatek, na których samolot przelatuje
    /// przez cały kadr — wizualnie są od siebie daleko, choć fizycznie to jedno
    /// naciśnięcie spustu. Kadencja jest tu pewniejszym sygnałem niż podobieństwo.
    private let burstWindow: TimeInterval = 3

    /// Najdłuższy dopuszczalny rozstęp całej serii.
    ///
    /// Bez tego ograniczenia łączenie łańcuchowe dryfuje: A pasuje do B,
    /// B do C, C do D — i po trzydziestu krokach w jednej serii lądują pierogi
    /// z garażem, choć każda kolejna para była poprawna. Kotwicą jest czas
    /// pierwszego zdjęcia serii, nie poprzedniego.
    private let maxSpan: TimeInterval = 10 * 60

    /// Ile ostatnich zdjęć serii bierzemy pod uwagę przy dołączaniu kolejnego.
    ///
    /// Porównywanie wyłącznie z bezpośrednim poprzednikiem rozrywa długie
    /// sekwencje: wystarczy, że w serii startów F-16 samolot przesunie się
    /// między dwiema klatkami bardziej niż zwykle, a seria pęka na pół.
    /// Oglądanie się na kilka ostatnich klatek przenosi pojedyncze skoki.
    private let lookback = 4

    // MARK: - Odciski

    /// Liczy brakujące odciski. Idzie po miniaturach, nie po oryginałach —
    /// deskryptor i tak operuje na małej rozdzielczości, a dzięki temu nic
    /// nie musi się ściągać z iCloud.
    func computeFingerprints(
        for assets: [PHAsset],
        library: PhotoLibrary,
        context: ModelContext
    ) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let existing = Set(
            (try? context.fetch(FetchDescriptor<Fingerprint>()))?.map(\.assetID) ?? []
        )
        let todo = assets.filter { !existing.contains($0.localIdentifier) }

        total = todo.count
        progress = 0

        // Nic do roboty to **wynik**, a nie brak wyniku. Bez tego kliknięcie
        // przy komplecie odcisków dawało błysk „0 / 0" i zniknięcie paska,
        // czyli obraz nieodróżnialny od awarii.
        guard !todo.isEmpty else {
            note = "Wszystkie odciski są już policzone (\(existing.count))."
            forgetNoteLater()
            return
        }

        for asset in todo {
            if let image = await thumbnail(for: asset, library: library),
               let values = Self.featurePrint(image) {
                context.insert(
                    Fingerprint(
                        assetID: asset.localIdentifier,
                        values: values,
                        takenAt: asset.creationDate ?? .distantPast
                    )
                )
            }
            progress += 1

            // Zapis partiami — przy 25 tysiącach zapis co rekord kosztuje
            // więcej niż samo liczenie odcisku.
            if progress % 200 == 0 { try? context.save() }
        }
        try? context.save()

        // Przeliczamy serie tylko wtedy, gdy faktycznie coś doszło. Wcześniej
        // szło to bezwarunkowo, więc kliknięcie przy komplecie odcisków
        // składało od nowa pięć tysięcy grup bez powodu.
        await rebuildGroups(context: context)

        note = "Policzono \(todo.count) odcisków. Serii: \(groups.count)."
        forgetNoteLater()
    }

    /// Komunikat znika sam. Zostawiony na stałe zamieniłby się w element
    /// interfejsu, a to jest wiadomość o zdarzeniu, nie stan.
    private func forgetNoteLater() {
        noteTimer?.cancel()
        noteTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    private func thumbnail(for asset: PHAsset, library: PhotoLibrary) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            var resumed = false
            _ = library.thumbnail(for: asset, side: 320) { image, degraded in
                // `opportunistic` woła handler dwa razy; interesuje nas wersja
                // pełna, ale gdy jej nie ma, bierzemy co jest.
                guard !resumed, !degraded || image == nil else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    private static func featurePrint(_ image: PlatformImage) -> [Float]? {
        guard let cgImage = image.asCGImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            return nil
        }
        return observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Grupowanie

    /// Wczytuje zapamiętane serie albo składa je na nowo, jeśli zmieniły się
    /// dane lub parametry. Ciężkie liczenie idzie poza główny wątek — inaczej
    /// interfejs stoi zamrożony przez kilkanaście sekund przy każdym starcie.
    func loadGroups(context: ModelContext) async {
        let count = (try? context.fetchCount(FetchDescriptor<Fingerprint>())) ?? 0
        guard count > 1 else { groups = []; return }

        let stamp = try? context.fetch(FetchDescriptor<SeriesStamp>()).first
        if stamp?.matches(count: count, threshold: Double(threshold),
                          timeWindow: timeWindow) == true {
            let cached = (try? context.fetch(FetchDescriptor<Series>())) ?? []
            if !cached.isEmpty {
                publish(cached)
                return
            }
        }
        await rebuildGroups(context: context)
    }

    /// Składa serie od zera i zapisuje wynik do składu.
    /// Ten sam klucz co w pliku wymiany — skład grupy, nie identyfikator.
    /// Dzięki temu werdykt przetrwa zarówno przeliczenie u siebie, jak
    /// i podróż na drugie urządzenie.
    static func key(for members: [String]) -> String {
        SyncFile.key(for: members)
    }

    func rebuildGroups(context: ModelContext) async {
        isGrouping = true
        defer { isGrouping = false }

        let prints = (try? context.fetch(
            FetchDescriptor<Fingerprint>(sortBy: [SortDescriptor(\.takenAt)])
        )) ?? []
        guard prints.count > 1 else { groups = []; return }

        // Przenosimy do zwykłych struktur, bo obiekty SwiftData nie przechodzą
        // przez granicę wątku.
        let input = prints.map { Entry(id: $0.assetID, takenAt: $0.takenAt, vector: $0.vector) }
        let window = timeWindow
        let cutoff = threshold

        let depth = lookback
        let burst = burstWindow
        let span = maxSpan
        let result = await Task.detached(priority: .userInitiated) {
            Similarity.assemble(input, burstWindow: burst, timeWindow: window,
                                maxSpan: span, threshold: cutoff, lookback: depth)
        }.value

        // Rozstrzygnięcia przeżywają przeliczenie, jeśli skład grupy się nie
        // zmienił.
        //
        // Wcześniej przebudowa kasowała serie razem z całą pracą turniejową —
        // a przebudowa dzieje się przy każdym nowym odcisku i przy każdym
        // ruchu suwakiem czułości. Wystarczyło zsynchronizować urządzenia,
        // żeby stracić wszystkie pojedynki. Kluczem jest skład grupy: gdy
        // ten sam, werdykt dalej obowiązuje; gdy inny — to już inna grupa
        // i słusznie wraca do kolejki.
        var verdicts: [String: (Date?, Bool, String?, Int)] = [:]
        for old in (try? context.fetch(FetchDescriptor<Series>())) ?? [] {
            if old.resolvedAt != nil || old.challengerIndex > 1 {
                verdicts[Self.key(for: old.members)] =
                    (old.resolvedAt, old.wasRejected, old.championID, old.challengerIndex)
            }
            context.delete(old)
        }
        for old in (try? context.fetch(FetchDescriptor<SeriesStamp>())) ?? [] {
            context.delete(old)
        }
        var created: [Series] = []
        var restored = 0
        for members in result {
            let series = Series(members: members)
            if let saved = verdicts[Self.key(for: members)] {
                series.resolvedAt = saved.0
                series.wasRejected = saved.1
                series.championID = saved.2
                series.challengerIndex = saved.3
                restored += 1
            }
            context.insert(series)
            created.append(series)
        }
        if restored > 0 { print("przywrócono \(restored) rozstrzygnięć serii") }
        context.insert(
            SeriesStamp(fingerprintCount: prints.count,
                        threshold: Double(cutoff), timeWindow: window)
        )
        try? context.save()

        publish(created)
    }

    /// Największe serie pierwsze — tam siedzi realny zysk z parowania.
    private func publish(_ series: [Series]) {
        let sorted = series.sorted { $0.members.count > $1.members.count }
        groups = sorted.map(\.members)
        seriesIDs = sorted.map(\.persistentModelID)
    }

    nonisolated private struct Entry: Sendable {
        let id: String
        let takenAt: Date
        let vector: Data
    }

    /// Czysta funkcja: żadnego stanu, żadnego SwiftData, więc bezpiecznie
    /// liczy się poza głównym wątkiem.
    ///
    /// Sąsiedzi w czasie trafiają do jednej serii, gdy dzieli ich mniej niż
    /// okno czasowe **i** mniej niż próg odległości wizualnej. Okno sprawdzamy
    /// pierwsze, bo odsiewa większość par bez rozpakowywania wektora.
    nonisolated private static func assemble(
        _ entries: [Entry], burstWindow: TimeInterval, timeWindow: TimeInterval,
        maxSpan: TimeInterval, threshold: Float, lookback: Int
    ) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = [entries[0].id]
        var recent: [[Float]] = [HalfFloat.unpack(entries[0].vector)]
        var anchor = entries[0].takenAt

        for i in 1..<entries.count {
            let apart = entries[i].takenAt.timeIntervalSince(entries[i - 1].takenAt)
            let span = entries[i].takenAt.timeIntervalSince(anchor)
            var close = false
            var vector: [Float]?

            if span > maxSpan {
                // Seria rozciągnęła się poza dopuszczalny czas — zamykamy ją
                // niezależnie od tego, jak podobna jest kolejna klatka.
                close = false
            } else if apart <= burstWindow {
                // Szybka kadencja **rozluźnia** próg, ale go nie znosi.
                //
                // Wcześniej łączyłem takie zdjęcia bez patrzenia na obraz —
                // dobre dla lecącego samolotu, fatalne dla kogoś, kto w 18
                // sekund pstryka pierogi, a potem odwraca się do garażu.
                // Mnożnik przepuszcza ruch w kadrze, ale nie zmianę tematu.
                let unpacked = HalfFloat.unpack(entries[i].vector)
                vector = unpacked
                close = recent.contains { distance($0, unpacked) < threshold * 2.2 }
            } else if apart <= timeWindow {
                let unpacked = HalfFloat.unpack(entries[i].vector)
                vector = unpacked
                // Wystarczy bliskość do którejkolwiek z kilku ostatnich klatek.
                close = recent.contains { distance($0, unpacked) < threshold }
            }

            if close {
                current.append(entries[i].id)
                let vector = vector ?? HalfFloat.unpack(entries[i].vector)
                recent.append(vector)
                if recent.count > lookback { recent.removeFirst() }
            } else {
                if current.count > 1 { result.append(current) }
                current = [entries[i].id]
                recent = [vector ?? HalfFloat.unpack(entries[i].vector)]
                anchor = entries[i].takenAt
            }
        }
        if current.count > 1 { result.append(current) }

        // Najliczniejsze serie pierwsze — tam siedzi realny zysk z parowania.
        return result.sorted { $0.count > $1.count }
    }

    /// Odległość euklidesowa. Vision ma własne `computeDistance`, ale wymaga
    /// żywego obiektu obserwacji — a my trzymamy same wektory, żeby dało się
    /// je zapisać między uruchomieniami.
    nonisolated private static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var sum: Float = 0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }
}

extension PlatformImage {
    var asCGImage: CGImage? {
        #if os(macOS)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}
