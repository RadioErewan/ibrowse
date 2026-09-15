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

    // MARK: - Cechy policzone przez system
    //
    // Doklejone do oceny, a nie trzymane osobno, **żeby pojechały istniejącą
    // rurą**. Plik wymiany wozi już oceny po identyfikatorach chmurowych, więc
    // cecha dopisana tutaj trafia na telefon bez nowej tabeli i bez drugiej
    // ścieżki scalania. Osobny model kosztowałby jedno i drugie.
    //
    // Żadna z tych liczb **nie jest decyzją** — wszystkie pochodzą z baz
    // systemu na macOS. Dlatego przy scalaniu nie biorą udziału w regule
    // „wygrywa nowszy": patrz `mergeRatings`. Rekord założony wyłącznie po to,
    // by je nieść, ma `isRated == false` i nadal liczy się jako nieoceniony.
    //
    // Zero znaczy **brak pomiaru**, nie wynik zerowy — system analizuje
    // bibliotekę w tle i część zdjęć zawsze czeka w kolejce.

    /// Ostrość, 0–1. W bazie systemu kolumna nazywa się `ZBLURRINESSSCORE`
    /// i nazwa kłamie: wartość rośnie wraz z ostrością, nie z rozmyciem.
    var sharpness: Double = 0

    /// Jakość ekspozycji, 0–1.
    var exposure: Double = 0

    /// Ile twarzy system znalazł na zdjęciu.
    var faces: Int = 0

    /// Twarze z co najmniej jednym zamkniętym okiem. Najkonkretniejszy powód
    /// odrzucenia portretu, jaki system liczy za nas.
    var eyesClosed: Int = 0

    /// Twarze z uśmiechem.
    var smiles: Int = 0

    /// Zrzut ekranu rozpoznany przez system — śmieć, który nie ma po co
    /// trafiać do oceniania.
    var isScreenshot: Bool = false

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

    /// Czy rekord niesie cokolwiek policzonego przez system.
    ///
    /// Decyduje o dwóch rzeczach: czy wpis jedzie do pliku wymiany (inaczej
    /// pojechałyby same oceny, a cechy zostałyby na Macu) i czy zdjęcie ma się
    /// w ogóle pojawić w zestawieniu cech.
    var hasFeatures: Bool {
        sharpness > 0 || exposure > 0 || faces > 0 || isScreenshot
    }

    /// Przepisuje cechy z drugiego urządzenia.
    ///
    /// Osobno od oceny i **bez dotykania `updatedAt`**, bo to nie jest zmiana,
    /// którą ktokolwiek zrobił — to ten sam pomiar systemu, tylko przywieziony.
    /// Wpisanie go jako świeżej zmiany kazałoby mu wygrać z prawdziwą oceną
    /// postawioną w międzyczasie na drugim urządzeniu.
    func adoptFeatures(from other: Review) {
        guard other.hasFeatures else { return }
        sharpness = other.sharpness
        exposure = other.exposure
        faces = other.faces
        eyesClosed = other.eyesClosed
        smiles = other.smiles
        isScreenshot = other.isScreenshot
    }

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

// MARK: - Pojedynek

extension Review {

    /// Różnica wag, przy której faworyt wygrywa mniej więcej trzy razy na
    /// cztery. Jeden punkt na skali 0–5 to wyraźnie inna liga, ale nie
    /// pewniak — i tak to właśnie ma znaczyć.
    static let duelScale: Double = 1.0

    /// Największa możliwa zmiana z jednego pojedynku, przy zdjęciu jeszcze
    /// nieoglądanym i przeciwniku o tej samej wadze.
    static let duelStep: Double = 0.5

    /// Malejący krok: zdjęcie oglądane dwadzieścia razy ma już ustaloną
    /// pozycję i nie powinno skakać po jednym pojedynku. Zwykły malejący
    /// współczynnik uczenia — im więcej wiadomo, tym ostrożniejsza poprawka.
    ///
    /// Swipe świadomie **tego nie używa**: tam decydujesz wprost i chcesz,
    /// żeby ruch był ruchem, a nie negocjacją z historią.
    private var learningRate: Double {
        Self.duelStep / (1 + Double(judgements) / 10)
    }

    /// Rozstrzyga pojedynek, przesuwając obie wagi wedle **zaskoczenia**.
    ///
    /// Stały krok psuł się przy dużych seriach na dwa sposoby naraz.
    /// Zwycięzca w serii 22 zdjęć wygrywał 21 razy po 0,25 i wychodził na
    /// sufit skali. A przegrany tracił zawsze tyle samo, więc „przegrało
    /// z najlepszym w serii" i „przegrało z byle czym" trafiały do składu
    /// jako ta sama liczba — cichszy błąd i groźniejszy, bo niewidoczny.
    ///
    /// Tutaj wygrana z równym sobie daje pełny krok, a z wyraźnie słabszym
    /// prawie nic: od faworyta oczekuje się wygranej, więc niczego nowego
    /// nie wnosi. Lider przestaje zarabiać w miarę wzrostu, więc **sufit
    /// znika sam** — bez sztucznego ograniczania. Symetrycznie przegrana
    /// z liderem kosztuje grosze, a z równym boli.
    static func settleDuel(winner: Review, loser: Review) {
        let gap = (loser.weight - winner.weight) / duelScale
        let expected = 1 / (1 + pow(10, gap))
        let surprise = 1 - expected

        // Stopy uczenia są różne dla obu zdjęć, więc pojedynek nie jest grą
        // o sumie zerowej. I dobrze: to nie zawody, tylko szacowanie — każda
        // strona poprawia własne oszacowanie na miarę tego, ile już wie.
        let up = winner.weight + winner.learningRate * surprise
        let down = loser.weight - loser.learningRate * surprise

        winner.set(up)
        loser.set(down)
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

    /// Oznacza albo odznacza **całą pulę** jednym przebiegiem.
    ///
    /// Nie przez `upsert` w pętli: tamto robi zapytanie i zapis na każde
    /// zdjęcie, więc dwieście oznaczeń to czterysta operacji na bazie
    /// i widoczne zacięcie. Tu jest jedno zapytanie, jeden zapis.
    ///
    /// Zwraca liczbę faktycznie zmienionych rekordów — nie liczbę zdjęć w puli.
    /// Te dwie rzeczy różnią się, gdy część była już oznaczona, i właśnie
    /// tę pierwszą warto pokazać.
    @discardableResult
    static func mark(
        _ assetIDs: [String], deleted: Bool, in context: ModelContext
    ) -> Int {
        guard !assetIDs.isEmpty else { return 0 }

        let wanted = Set(assetIDs)
        let existing = Dictionary(
            ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
                .filter { wanted.contains($0.assetID) }
                .map { ($0.assetID, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        var changed = 0
        for id in wanted {
            if let review = existing[id] {
                guard review.markedForDeletion != deleted else { continue }
                review.markedForDeletion = deleted
                review.updatedAt = .now
                changed += 1
            } else {
                // Zdejmowanie oznaczenia z nieistniejącego rekordu to nic —
                // nie zakładamy pustych ocen tylko po to, żeby zapisać w nich
                // brak decyzji.
                guard deleted else { continue }
                let fresh = Review(assetID: id)
                fresh.markedForDeletion = true
                context.insert(fresh)
                changed += 1
            }
        }
        if changed > 0 { try? context.save() }
        return changed
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

    /// Postęp turnieju: kto dotąd wygrywa i który pretendent jest następny.
    ///
    /// Wcześniej to były `@State` w widoku, więc wyjście z pojedynku w połowie
    /// serii kasowało całą pracę. Przy seriach trzyelementowych niewidoczne,
    /// przy dwudziestu — kosztowne, a to właśnie duże serie są powodem, dla
    /// którego ten tryb istnieje.
    var championID: String?
    var challengerIndex: Int = 1

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
