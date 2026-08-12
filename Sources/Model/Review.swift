import Foundation
import SwiftData

/// Ocena zdjęcia jako **jedna waga ciągła**.
///
/// Apple Photos nie ma ocen gwiazdkowych — zna tylko binarne „ulubione" —
/// więc skład jest własny. Kluczowa decyzja: waga to jedna liczba, do której
/// piszą wszystkie trzy sposoby oceniania. Klawiatura ustawia ją wprost,
/// swipe na telefonie przesuwa o krok, wygrana w parowaniu podbija.
/// Gwiazdki w siatce są tylko widokiem tej liczby, nie osobną skalą.
@Model
final class Review {
    /// `localIdentifier` z PHAsset — stabilny w obrębie biblioteki.
    @Attribute(.unique) var assetID: String = ""

    /// Skala 0–5, ciągła. Wartość neutralna to środek, więc zdjęcie
    /// nietknięte nie udaje ani dobrego, ani złego.
    var weight: Double = Review.neutral

    /// Odróżnia „nigdy nie oceniane" od „ocenione i wyszło neutralnie".
    /// Bez tego filtr nieocenionych nie ma jak działać.
    var isRated: Bool = false

    /// Ile razy zdjęcie przeszło przez ocenianie. Przy wielokrotnych
    /// podejściach do archiwum pokazuje, co jest przemyślane, a co ledwo
    /// dotknięte.
    var judgements: Int = 0

    var markedForDeletion: Bool = false
    var updatedAt: Date = Date.now

    init(assetID: String) {
        self.assetID = assetID
    }
}

extension Review {
    static let neutral: Double = 2.5
    static let range: ClosedRange<Double> = 0...5

    /// Krok przesunięcia. Cztery kroki to jedna gwiazdka — na tyle mało,
    /// żeby swipe nie był nieodwracalny, i na tyle dużo, żeby po kilku
    /// przebiegach coś się faktycznie ułożyło.
    static let step: Double = 0.25

    /// Gwiazdki to zaokrąglona waga, nie osobne pole.
    var stars: Int { isRated ? Int(weight.rounded()) : 0 }

    func set(_ value: Double) {
        weight = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        isRated = true
        judgements += 1
        updatedAt = .now
    }

    func nudge(_ direction: Double) {
        set(weight + direction * Self.step)
    }
}

extension Review {
    /// Znajduje ocenę albo tworzy pustą. Jedno miejsce zapisu, żeby widoki
    /// nie musiały wiedzieć, czy rekord już istnieje.
    @discardableResult
    static func upsert(
        assetID: String,
        in context: ModelContext,
        mutate: (Review) -> Void
    ) -> Review {
        let descriptor = FetchDescriptor<Review>(
            predicate: #Predicate { $0.assetID == assetID }
        )
        let review = (try? context.fetch(descriptor).first) ?? {
            let fresh = Review(assetID: assetID)
            context.insert(fresh)
            return fresh
        }()
        mutate(review)
        try? context.save()
        return review
    }
}

/// Odcisk wizualny z Vision, trzymany żeby nie liczyć go przy każdym starcie.
///
/// Odległość liczymy sami z surowego wektora, dzięki czemu da się go zapisać
/// i wczytać bez odtwarzania obiektu `VNFeaturePrintObservation`.
@Model
final class Fingerprint {
    @Attribute(.unique) var assetID: String = ""

    /// Wektor spakowany do half floatów — 1536 B zamiast 3072 B.
    /// Pomiar na realnej próbce: kwantyzacja nie zmienia ani jednej decyzji
    /// o przynależności do serii, a skład schodzi z ~78 do ~39 MB.
    var vector: Data = Data()

    /// Data zrobienia zdjęcia — kopia z PHAsset, żeby grupowanie po oknie
    /// czasowym nie musiało odpytywać biblioteki.
    var takenAt: Date = Date.distantPast

    init(assetID: String, values: [Float], takenAt: Date) {
        self.assetID = assetID
        self.vector = HalfFloat.pack(values)
        self.takenAt = takenAt
    }

    var floats: [Float] { HalfFloat.unpack(vector) }
}

/// Zapamiętana seria — wynik grupowania, nie dane źródłowe.
///
/// Bez tego każde uruchomienie przelicza grupy od zera: wczytuje wszystkie
/// odciski i liczy odległości, blokując przy tym główny wątek. Przy 25 tysiącach
/// zdjęć to kilkanaście sekund, a rośnie liniowo z biblioteką.
@Model
final class Series {
    var members: [String] = []
    var builtAt: Date = Date.now

    /// Kiedy seria została rozstrzygnięta albo świadomie pominięta.
    ///
    /// Bez tego każde wejście w parowanie zaczyna od pierwszej serii i nie
    /// widać żadnego postępu — a to jest praca rozłożona na wiele podejść
    /// przez lata, nie jedno posiedzenie.
    var resolvedAt: Date?

    /// Zestawienie było błędne — te zdjęcia nie tworzą serii.
    ///
    /// To nie to samo co pominięcie. Pominięcie znaczy „nie teraz",
    /// odrzucenie znaczy „algorytm się pomylił" — a liczba odrzuceń przy danej
    /// czułości mówi wprost, czy próg jest źle ustawiony. Bez tego rozróżnienia
    /// nie ma z czego wnioskować.
    var wasRejected: Bool = false

    init(members: [String]) {
        self.members = members
    }

    var isResolved: Bool { resolvedAt != nil }
}

/// Odcisk parametrów, którymi policzono serie. Gdy którykolwiek się zmieni —
/// dojdą nowe zdjęcia albo przesuniesz próg — cache jest nieważny i grupy
/// trzeba złożyć na nowo.
@Model
final class SeriesStamp {
    var fingerprintCount: Int = 0
    var threshold: Double = 0
    var timeWindow: Double = 0

    init(fingerprintCount: Int, threshold: Double, timeWindow: Double) {
        self.fingerprintCount = fingerprintCount
        self.threshold = threshold
        self.timeWindow = timeWindow
    }

    func matches(count: Int, threshold: Double, timeWindow: Double) -> Bool {
        fingerprintCount == count
            && abs(self.threshold - threshold) < 0.0001
            && abs(self.timeWindow - timeWindow) < 0.0001
    }
}
