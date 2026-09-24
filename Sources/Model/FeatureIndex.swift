import Foundation
import SwiftData

/// Cechy policzone przez system, wyjęte z bazy **raz** i trzymane jako zwykłe
/// struktury.
///
/// Mieszkają w `Review`, bo tamtędy jadą na telefon — ale sięganie po nie
/// przez `@Query` byłoby zabójcze. Rekordów z cechami jest tyle, co zdjęć
/// (25 tysięcy), a zapytanie unieważnia widok przy **każdym** zapisie: każda
/// ocena przebudowywałaby całą siatkę razem ze słownikiem. Do tego ocenianie
/// pyta o rekordy niosące decyzję i celowo ich nie widzi.
///
/// Dlatego cechy czytamy osobno i jednorazowo. Zmieniają się tylko przy
/// wczytaniu z baz systemu albo przy synchronizacji — czyli wtedy, gdy ktoś
/// o to wprost poprosi, a nie w trakcie pracy.
@MainActor
final class FeatureIndex: ObservableObject {

    /// Sam pomiar, bez obiektu modelu. Struktura nie trzyma kontekstu,
    /// nie unieważnia widoków i mieści się w słowniku, po którym wolno
    /// chodzić w pętli.
    struct Row {
        var sharpness: Double = 0
        var exposure: Double = 0
        var faces: Int = 0
        var eyesClosed: Int = 0
        var smiles: Int = 0
        var isScreenshot: Bool = false

        /// Miary ze spisu, **po jednej na pozycję spisu**, `nan` = brak.
        ///
        /// Tablica zamiast słownika, bo liczniki w panelu filtru chodzą po
        /// wszystkich miarach dla każdego zdjęcia: czterdzieści odczytów na
        /// 26 tysięcy zdjęć przy każdej zmianie warunków. Indeks w tablicy
        /// kosztuje tyle co nic, haszowanie klucza już nie.
        var values: [Float] = []

        func value(at slot: Int) -> Float? {
            guard slot < values.count else { return nil }
            let v = values[slot]
            return v.isNaN ? nil : v
        }
    }

    /// Co wiadomo o jednej mierze w **tej** bibliotece.
    struct Stat {
        var count = 0
        var min: Float = .infinity
        var max: Float = -.infinity

        /// Próg domyślny: granica najgorszej dziesiątej części zdjęć. Tak, żeby
        /// licznik przy wierszu mówił coś, zanim ktoś ruszy suwak.
        var defaultThreshold: Double = 0

        /// Rozkład na 24 przedziały między minimum a maksimum. Rysowany pod
        /// suwakiem, bo przy miarach znakowanych — ikoniczność od −2 do 1 —
        /// dopiero kształt rozkładu pokazuje, gdzie w ogóle leżą zdjęcia i która
        /// strona skali jest tą rzadką.
        var histogram: [Int] = []

        /// Przedział domyślny: najgorsza dziesiąta część zdjęć, od właściwej
        /// strony skali.
        func defaultRange(higherIsBetter: Bool) -> ClosedRange<Double> {
            let lo = Double(min), hi = Double(max)
            let t = Swift.min(Swift.max(defaultThreshold, lo), hi)
            return higherIsBetter ? lo...t : t...hi
        }
    }

    @Published private(set) var rows: [String: Row] = [:]

    /// Rośnie przy każdym wczytaniu. Filtry używają go jako podpisu pamięci
    /// podręcznej — bez tego zbiór roboczy nie zauważyłby świeżych cech.
    @Published private(set) var revision = 0

    /// Słowa do wyszukiwania po UUID zdjęcia (36 znaków, jak trafienia
    /// wyszukiwania w `Filters`). Pochodzą z eksportera.
    private(set) var terms: [String: String] = [:]

    /// Rozkład każdej miary, kluczowany kodem.
    @Published private(set) var stats: [UInt8: Stat] = [:]

    /// Miary, które w tej bibliotece niosą sygnał — w kolejności spisu.
    @Published private(set) var available: [Measure] = []

    /// Pozycja miary w tablicy `Row.values`.
    let slots: [UInt8: Int] = Dictionary(
        uniqueKeysWithValues: Measure.all.enumerated().map { ($0.element.code, $0.offset) }
    )

    var count: Int { rows.count }
    var isEmpty: Bool { rows.isEmpty }

    subscript(id: String) -> Row? { rows[id] }

    func value(_ code: UInt8, for id: String) -> Float? {
        guard let slot = slots[code] else { return nil }
        return rows[id]?.value(at: slot)
    }

    /// Granica najgorszej dziesiątej części — **odporna na skoki**.
    ///
    /// Naiwnie to wartość na pozycji jednej dziesiątej. Ale kuracja ma 17 882
    /// zdjęcia (prawie 70% biblioteki) z wartością dokładnie 0,5, najpewniej
    /// zapisem „brak zdania" w środku skali. Dziesiąty centyl wpadał w ten
    /// skok, a przedział „do 0,5 włącznie" zgarniał go w całości: zamiast
    /// dwóch i pół tysiąca zdjęć dostawało się osiemnaście.
    ///
    /// Dlatego gdy wartość graniczna jest częścią remisu, który rozdmuchałby
    /// wynik ponad dwukrotność celu, cięcie schodzi na najbliższą wartość
    /// **przed** remisem. Wychodzi trochę mniej niż dziesiąta część, ale to
    /// dziesiąta część zdjęć naprawdę gorszych, a nie wszystkich przeciętnych.
    nonisolated static func tenthCut(_ sorted: [Float], higherIsBetter: Bool) -> Float {
        let n = sorted.count
        guard n > 0 else { return 0 }
        let target = max(1, n / 10)

        // Liczymy zawsze od gorszej strony: przy „wyżej gorzej" odwracamy.
        let ordered = higherIsBetter ? sorted : sorted.reversed()
        let cut = ordered[target - 1]
        func worse(_ a: Float, _ b: Float) -> Bool { higherIsBetter ? a < b : a > b }

        // Ile zdjęć jest „nie lepszych" od cięcia, razem z remisem.
        var through = target
        while through < n && !worse(cut, ordered[through]) { through += 1 }
        guard through > target * 2 else { return cut }

        // Pierwsze wystąpienie wartości granicznej — przed nim leży wartość
        // ściśle gorsza, i tam kończymy, o ile w ogóle coś tam jest.
        var first = target - 1
        while first > 0 && !worse(ordered[first - 1], cut) { first -= 1 }
        return first > 0 ? ordered[first - 1] : cut
    }

    func load(context: ModelContext) {
        // Bez predykatu: rekordy niosące wyłącznie spakowane miary nie dają się
        // odsiać zapytaniem, bo długości bloba SwiftData nie przełoży na SQL.
        // Wczytanie całości dzieje się raz na import albo synchronizację.
        let found = (try? context.fetch(FetchDescriptor<Review>())) ?? []
        let width = Measure.all.count
        var perMeasure: [[Float]] = Array(repeating: [], count: width)

        var built: [String: Row] = [:]
        built.reserveCapacity(found.count)
        var loadedTerms: [String: String] = [:]
        for review in found where !review.searchTerms.isEmpty {
            loadedTerms[String(review.assetID.prefix(36))] = review.searchTerms
        }
        terms = loadedTerms

        for review in found where review.hasFeatures {
            var row = Row(
                sharpness: review.sharpness,
                exposure: review.exposure,
                faces: review.faces,
                eyesClosed: review.eyesClosed,
                smiles: review.smiles,
                isScreenshot: review.isScreenshot
            )
            if !review.measures.isEmpty {
                var values = [Float](repeating: .nan, count: width)
                for (code, value) in MeasurePacking.unpack(review.measures) {
                    guard let slot = slots[code] else { continue }
                    values[slot] = value
                    perMeasure[slot].append(value)
                }
                row.values = values
            }
            built[review.assetID] = row
        }

        var computed: [UInt8: Stat] = [:]
        for (slot, measure) in Measure.all.enumerated() {
            let values = perMeasure[slot]
            guard !values.isEmpty else { continue }
            var stat = Stat()
            stat.count = values.count
            stat.min = values.min() ?? 0
            stat.max = values.max() ?? 0
            if measure.kind == .continuous {
                let sorted = values.sorted()
                stat.defaultThreshold = Double(Self.tenthCut(sorted, higherIsBetter: measure.higherIsBetter))
                if stat.max > stat.min {
                    var bins = [Int](repeating: 0, count: 24)
                    let span = stat.max - stat.min
                    for value in values {
                        let bin = Int(((value - stat.min) / span) * 23.999)
                        bins[Swift.min(Swift.max(bin, 0), 23)] += 1
                    }
                    stat.histogram = bins
                }
            }
            computed[measure.code] = stat
        }

        rows = built
        stats = computed
        available = Measure.all.filter { measure in
            guard let stat = computed[measure.code] else { return false }
            switch measure.kind {
            case .flag: return stat.count > 0
            case .continuous: return stat.max > stat.min
            }
        }
        revision += 1
    }
}
