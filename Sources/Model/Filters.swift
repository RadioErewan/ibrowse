import Photos
import SwiftUI

/// Jeden zestaw warunków na całą aplikację.
///
/// Wcześniej zakres lat siedział w `PhotoLibrary`, a stan oceny w `CullView` —
/// więc siatka i ocenianie pokazywały różne rzeczy i nie dało się przejść
/// z jednego do drugiego bez gubienia kontekstu. Filtry, tak jak wskaźnik
/// miejsca, są własnością całej aplikacji, nie pojedynczego widoku.
///
/// Podział na dwa etapy jest celowy. **Rok i szukanie** zmieniają się rzadko,
/// więc ich wynik trzymamy policzony (`base`). **Ocena** zmienia się przy
/// każdym naciśnięciu klawisza, więc jest zwykłym predykatem nakładanym
/// w widoku — przeliczanie 25 tysięcy pozycji przy każdej ocenie byłoby
/// marnotrawstwem, a sprawdzenie jednego wpisu w słowniku kosztuje tyle co nic.
///
/// **Cechy i kolejność mieszkają tutaj, nie w osobnym widoku.** Wcześniej
/// zestawienia „od najbardziej poruszonych" były własną zakładką z własnym
/// zbiorem — i to był błąd, którego nie dało się obejść. Kliknięcie w takie
/// zestawienie wchodziło w ocenianie, a ono chodzi po `apply(...)`: zbiór
/// cech ginął w chwili kliknięcia i następne zdjęcie przychodziło z zupełnie
/// innej kolejki. Dopóki zbiory są dwa, nie da się tego naprawić — więc jest
/// jeden, a „poruszone" to po prostu warunek i porządek, tak samo jak rok.
@MainActor
final class Filters: ObservableObject {

    /// Stan oceny. Rozdzielony od zakresu gwiazdek, bo „nieocenione" nie jest
    /// punktem na skali — to brak punktu.
    enum Standing: String, CaseIterable, Identifiable {
        case all = "wszystkie"
        case unrated = "nieocenione"
        case rated = "ocenione"
        case marked = "do usunięcia"
        var id: String { rawValue }
    }

    /// Cecha policzona przez system, użyta jako warunek.
    ///
    /// Nie jest oceną i niczego nie waży — to inne pytanie do tego samego
    /// archiwum. Zero w pomiarze znaczy „nie policzono", a nie „beznadziejne",
    /// więc nigdzie nie liczy się jako wynik najgorszy.
    enum Feature: String, CaseIterable, Identifiable {
        case any = "bez warunku"
        case blurry = "poruszone"
        case dark = "źle naświetlone"
        case eyes = "zamknięte oczy"
        case screenshots = "zrzuty ekranu"
        var id: String { rawValue }

        /// Czy warunek jest ciągły — tylko wtedy próg ma sens.
        var isContinuous: Bool { self == .blurry || self == .dark }

        var hint: String {
            switch self {
            case .any: "wszystko, co przeszło pozostałe warunki"
            case .blurry: "niżej = bardziej rozmyte"
            case .dark: "niżej = gorzej naświetlone"
            case .eyes: "ktoś na zdjęciu ma zamknięte oczy"
            case .screenshots: "rozpoznane przez system"
            }
        }
    }

    /// Porządek zbioru roboczego — czyli to, co znaczy „następne zdjęcie".
    ///
    /// Osobny od warunku celowo: chcieć obejrzeć same zrzuty ekranu po kolei
    /// to co innego niż obejrzeć całe archiwum od najbardziej poruszonych.
    enum Order: String, CaseIterable, Identifiable {
        case library = "jak w bibliotece"
        case day = "po dniu"
        case blurry = "od poruszonych"
        case dark = "od niedoświetlonych"
        case eyes = "od zamkniętych oczu"
        case best = "od najlepszych"
        case worst = "od najgorszych"
        var id: String { rawValue }

        /// Czy ta kolejność dzieli siatkę na nagłówki.
        ///
        /// Grupowanie **nie jest osobną osią** — to pozycja tej samej listy,
        /// wykluczająca się z pozostałymi. Gdyby było osią, trzeba by
        /// odpowiedzieć, co znaczy „następne zdjęcie" przy grupowaniu po dniu
        /// i sortowaniu po poruszeniu naraz: kolejne w dniu czy kolejny dzień.
        /// Tak kolejka zostaje płaska, a nagłówki są w niej podziałami.
        var isGrouped: Bool { self == .day }
    }

    @Published var feature: Feature = Feature(
        rawValue: UserDefaults.standard.string(forKey: "library.feature") ?? ""
    ) ?? .any {
        didSet { UserDefaults.standard.set(feature.rawValue, forKey: "library.feature") }
    }

    @Published var order: Order = Order(
        rawValue: UserDefaults.standard.string(forKey: "library.order") ?? ""
    ) ?? .library {
        didSet { UserDefaults.standard.set(order.rawValue, forKey: "library.order") }
    }

    /// Próg dla warunków ciągłych: bierzemy to, co **poniżej** niego.
    @Published var threshold: Double =
        UserDefaults.standard.object(forKey: "library.threshold") as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(threshold, forKey: "library.threshold") }
    }

    @Published var fromYear: Int = UserDefaults.standard.object(forKey: "library.fromYear") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(fromYear, forKey: "library.fromYear"); rebuild() }
    }
    @Published var toYear: Int = UserDefaults.standard.object(forKey: "library.toYear") as? Int ?? 9999 {
        didSet { UserDefaults.standard.set(toYear, forKey: "library.toYear"); rebuild() }
    }

    @Published var standing: Standing = .all
    /// Które liczby gwiazdek przepuszczamy — **zbiór, nie zakres**.
    ///
    /// Zakres z dwoma końcami wymuszał regułę „pierwsze stuknięcie zwija,
    /// drugie rozciąga", której nie dało się odgadnąć z wyglądu kontrolki.
    /// Gorzej: nie pozwalał wybrać trójki i piątki z pominięciem czwórki,
    /// a to jest normalne pytanie przy przeglądzie.
    ///
    /// Pusty zbiór znaczy **bez zawężania**, nie „nic". Inaczej wyłączenie
    /// ostatniej gwiazdki kasowałoby cały widok i wyglądało jak awaria.
    ///
    /// Zero jest pełnoprawną pozycją, bo `Review.stars` to zaokrąglona waga
    /// z zakresu 0–5, a wypchnięcie zdjęcia na samo dno to sposób oznaczania
    /// go do skasowania. Poprzedni zakres zaczynał się od jedynki i te zdjęcia
    /// były niewidoczne.
    @Published var stars: Set<Int> = []

    /// Szukanie po tym, co widzi system: etykiety scen, imiona, nazwy miejsc
    /// i słowa odczytane ze zdjęć.
    @Published var query: String = "" {
        didSet { guard query != oldValue else { return }; scheduleSearch() }
    }

    /// Zdjęcia po zakresie lat i szukaniu — bez warunku oceny.
    @Published private(set) var base: [PHAsset] = []

    /// Rośnie przy każdym przeliczeniu bazy. Sama liczba pozycji nie
    /// wystarcza jako podpis: „2018–2018" i „2019–2019" potrafią dać tyle
    /// samo zdjęć, a to zupełnie inny zbiór.
    @Published private(set) var baseStamp = 0
    @Published private(set) var isSearching = false
    @Published private(set) var searchNote: String?

    private var all: [PHAsset] = []
    /// `nil` znaczy „nie szukamy", a pusty zbiór — „szukaliśmy i nic nie ma".
    /// Bez tego rozróżnienia puste wyszukiwanie kasowałoby cały widok.
    private var matches: Set<String>?
    private var searchTask: Task<Void, Never>?
    private var cacheKey = ""
    private var cached: [PHAsset] = []

    #if os(macOS)
    private let store = MetadataStore.shared
    #endif

    // MARK: - Źródło

    func adopt(_ assets: [PHAsset]) {
        all = assets
        rebuild()
    }

    private func rebuild() {
        let calendar = Calendar.current
        let limitedByYear = fromYear > 0 || toYear < 9999
        let matches = self.matches

        base = all.filter { asset in
            if limitedByYear {
                guard let date = asset.creationDate else { return false }
                let year = calendar.component(.year, from: date)
                guard year >= fromYear && year <= toYear else { return false }
            }
            if let matches {
                guard matches.contains(String(asset.localIdentifier.prefix(36))) else { return false }
            }
            return true
        }
        baseStamp += 1
        cacheKey = ""
    }

    // MARK: - Zbiór roboczy

    /// Jedna kolejka na całą aplikację: te same zdjęcia, w tej samej
    /// kolejności, w siatce i w ocenianiu.
    ///
    /// Wynik trzymamy policzony, bo wołają o niego właściwości obliczane
    /// — `workingSet` w ocenianiu sięga tu kilka razy na jedno odrysowanie,
    /// a sortowanie 26 tysięcy pozycji przy każdym z nich stawia interfejs.
    /// Podpis celowo **nie zawiera ocen poszczególnych zdjęć**: gdyby zawierał,
    /// zbiór przestawiałby się pod palcem przy każdej ocenie i zdjęcie
    /// uciekałoby spod kursora w trakcie pracy.
    func apply(_ reviews: [String: Review], features: FeatureIndex) -> [PHAsset] {
        let key = "\(baseStamp)|\(standing.rawValue)"
            + "|\(stars.sorted().map(String.init).joined(separator: ","))"
            + "|\(feature.rawValue)|\(threshold)|\(order.rawValue)"
            + "|\(reviews.count)|\(features.revision)"
        if key == cacheKey { return cached }

        var result = base
        if standing != .all {
            result = result.filter { accepts(reviews[$0.localIdentifier]) }
        }
        if feature != .any {
            result = result.filter { carries(features[$0.localIdentifier]) }
        }
        result = sorted(result, reviews: reviews, features: features)

        cacheKey = key
        cached = result
        return result
    }

    /// Czy zdjęcie spełnia warunek cechy. Brak pomiaru to **nie** wynik zerowy
    /// — nieprzeanalizowane zdjęcie nie jest poruszone, tylko niezbadane.
    private func carries(_ row: FeatureIndex.Row?) -> Bool { carries(row, as: feature) }

    func carries(_ row: FeatureIndex.Row?, as feature: Feature) -> Bool {
        guard feature != .any else { return true }
        guard let row else { return false }
        switch feature {
        case .any: return true
        case .blurry: return row.sharpness > 0 && row.sharpness < threshold
        case .dark: return row.exposure > 0 && row.exposure < threshold
        case .eyes: return row.eyesClosed > 0
        case .screenshots: return row.isScreenshot
        }
    }

    /// Zdjęcia bez pomiaru lądują **na końcu**, nie na początku. Inaczej
    /// „od poruszonych" zaczynałoby się od tysięcy zdjęć, o których nie wiemy
    /// nic — a to najgorsza możliwa odpowiedź na to pytanie.
    private func sorted(
        _ assets: [PHAsset], reviews: [String: Review], features: FeatureIndex
    ) -> [PHAsset] {
        switch order {
        case .library:
            return assets
        case .day:
            // Najnowsze pierwsze — dzień bez zdjęcia nie istnieje, więc brak
            // daty ląduje na końcu razem z resztą nieznanego.
            return assets.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
        case .blurry, .dark:
            let value: (FeatureIndex.Row) -> Double =
                order == .blurry ? { $0.sharpness } : { $0.exposure }
            return assets.sorted { a, b in
                let x = features[a.localIdentifier].map(value) ?? 0
                let y = features[b.localIdentifier].map(value) ?? 0
                return (x > 0 ? x : .infinity) < (y > 0 ? y : .infinity)
            }
        case .eyes:
            return assets.sorted {
                (features[$0.localIdentifier]?.eyesClosed ?? 0)
                    > (features[$1.localIdentifier]?.eyesClosed ?? 0)
            }
        case .best, .worst:
            let ascending = order == .worst
            return assets.sorted { a, b in
                // Nieocenione trzymamy na końcu w obu kierunkach: brak oceny
                // nie jest ani piątką, ani zerem.
                let x = reviews[a.localIdentifier].flatMap { $0.isRated ? $0.weight : nil }
                let y = reviews[b.localIdentifier].flatMap { $0.isRated ? $0.weight : nil }
                switch (x, y) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case (let x?, let y?): return ascending ? x < y : x > y
                }
            }
        }
    }

    // MARK: - Liczniki

    /// Ile zdjęć dałby **każdy** warunek, gdyby go teraz wybrać.
    ///
    /// To jest najważniejsza rzecz w panelu i powód, dla którego warunki są
    /// wierszami, a nie przełącznikiem. Dotąd licznik był jeden i mówił, co
    /// wyszło **po** wyborze — czyli zawężanie było strzelaniem w ciemno
    /// i wychodzeniem za każdym razem, żeby sprawdzić, czy cokolwiek zostało.
    /// Licznik przy każdym wierszu odpowiada, zanim klikniesz.
    ///
    /// Liczby są **wzajemnie uwarunkowane**: przy ocenach liczymy z nałożoną
    /// cechą, przy cechach z nałożonym stanem oceny. Inaczej wiersz obiecywałby
    /// tysiąc zdjęć i dawał trzy, bo reszta odpadłaby na drugim warunku.
    struct Tally {
        var standing: [Standing: Int] = [:]
        var feature: [Feature: Int] = [:]
        /// Ile zdjęć ma daną liczbę gwiazdek — liczone **bez** bieżącego
        /// wyboru gwiazdek, bo inaczej każda pozycja poza wybraną pokazywałaby
        /// zero i kontrolka przestawałaby cokolwiek mówić.
        var stars: [Int: Int] = [:]
        var total = 0
    }

    func tally(_ reviews: [String: Review], features: FeatureIndex) -> Tally {
        var result = Tally()

        for asset in base {
            let id = asset.localIdentifier
            let review = reviews[id]
            let row = features[id]

            let passesFeature = carries(row, as: feature)
            let passesStanding = accepts(review, as: standing)

            if passesFeature {
                for value in Standing.allCases where accepts(review, as: value) {
                    result.standing[value, default: 0] += 1
                }
            }
            if passesStanding {
                for value in Feature.allCases where carries(row, as: value) {
                    result.feature[value, default: 0] += 1
                }
            }
            if passesFeature, let review, review.isRated {
                result.stars[review.stars, default: 0] += 1
            }
            if passesFeature && passesStanding { result.total += 1 }
        }
        return result
    }

    /// Podpis na kafelku: liczba, przez którą zdjęcie znalazło się w tym
    /// miejscu. Bez niego zestawienie jest ciągiem zdjęć bez wytłumaczenia,
    /// dlaczego stoją w tej kolejności.
    func badge(for id: String, in features: FeatureIndex) -> String? {
        guard let row = features[id] else { return nil }
        switch axis {
        case .none: return nil
        case .sharpness: return row.sharpness > 0 ? String(format: "%.2f", row.sharpness) : nil
        case .exposure: return row.exposure > 0 ? String(format: "%.2f", row.exposure) : nil
        case .eyes:
            guard row.eyesClosed > 0 else { return nil }
            return "\(row.eyesClosed) z \(max(row.faces, row.eyesClosed))"
        case .screenshot: return row.isScreenshot ? "zrzut" : nil
        }
    }

    /// Miara, która jest akurat w grze. Warunek ma pierwszeństwo przed
    /// porządkiem: skoro oglądam same zrzuty, to podpis ma mówić o zrzutach.
    enum Axis { case none, sharpness, exposure, eyes, screenshot }

    var axis: Axis {
        switch feature {
        case .blurry: return .sharpness
        case .dark: return .exposure
        case .eyes: return .eyes
        case .screenshots: return .screenshot
        case .any:
            switch order {
            case .blurry: return .sharpness
            case .dark: return .exposure
            case .eyes: return .eyes
            default: return .none
            }
        }
    }

    func accepts(_ review: Review?) -> Bool { accepts(review, as: standing) }

    func accepts(_ review: Review?, as standing: Standing) -> Bool {
        switch standing {
        case .all:
            return true
        case .unrated:
            return review?.isRated != true
        case .rated:
            guard let review, review.isRated else { return false }
            return stars.isEmpty || stars.contains(review.stars)
        case .marked:
            return review?.markedForDeletion == true
        }
    }

    // MARK: - Szukanie

    var isActive: Bool {
        fromYear > 0 || toYear < 9999 || standing != .all || !query.isEmpty
            || feature != .any || order != .library || !stars.isEmpty
    }

    func clear() {
        query = ""
        standing = .all
        feature = .any
        order = .library
        stars = []
        fromYear = 0
        toYear = 9999
    }

    /// Zwłoka jest po to, żeby nie odpytywać bazy przy każdej literze —
    /// przy pisaniu „kajak" byłoby to pięć przelotów zamiast jednego.
    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count >= 2 else {
            matches = nil
            searchNote = nil
            isSearching = false
            rebuild()
            return
        }

        #if os(macOS)
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }

            self.isSearching = true
            let found = await self.store.search(text)
            let failure = await self.store.currentFailure()
            guard !Task.isCancelled else { return }

            self.matches = found
            self.searchNote = failure ?? (found.isEmpty ? "Nic nie pasuje do: \(text)" : nil)
            self.isSearching = false
            self.rebuild()
        }
        #else
        // Indeks wyszukiwania Apple leży w pakiecie biblioteki na dysku Maca.
        // Na telefonie nie ma go skąd wziąć — PhotoKit nie udostępnia ani
        // etykiet, ani tekstu, a przepisywanie 285 tysięcy przypisań przez
        // albumy byłoby lekarstwem gorszym od choroby.
        matches = nil
        searchNote = "Szukanie po treści działa tylko na Macu — na telefonie nie ma tego indeksu."
        rebuild()
        #endif
    }
}
