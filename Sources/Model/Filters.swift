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

    /// Ocena jako **jedna skala z siedmioma pozycjami**, nie dwie kontrolki.
    ///
    /// Wcześniej były cztery wiersze stanu — wszystkie, nieocenione, ocenione,
    /// do usunięcia — a pod nimi, ukryta do czasu wybrania „ocenionych", skala
    /// gwiazdek. Dwie kontrolki na jedno pytanie, przy czym drugiej nie dało
    /// się znaleźć, dopóki nie trafiło się w pierwszą.
    ///
    /// Pomysł Radka: **to jest ten sam wybór**. „Nieocenione" to pozycja
    /// `brak`, „ocenione" to wszystkie sześć gwiazdek naraz, „wszystkie" to
    /// nic niezaznaczonego. A przy okazji dochodzi to, czego tamten układ nie
    /// umiał wyrazić: sam dół skali, albo oceny bez dna, albo nieocenione
    /// razem z zerami.
    enum Grade: Int, CaseIterable, Identifiable, Hashable {
        /// Oznaczone do usunięcia — **pozycja na skali, poniżej wszystkiego**.
        ///
        /// Pomysł Radka. Wcześniej był to osobny warunek przecinający się ze
        /// skalą, żeby dało się zapytać „oznaczone i z dna". Ale skoro zdjęcie
        /// jest już skazane, jego gwiazdki przestają cokolwiek znaczyć — nie ma
        /// czego przecinać. Jako pozycja skali kosztuje jedną kontrolkę mniej
        /// i przy okazji znika z liczników ocen, więc te mówią o tym, co
        /// jeszcze jest w grze.
        case deleted = -2
        case unrated = -1
        case zero = 0, one, two, three, four, five
        var id: Int { rawValue }

        var isUnrated: Bool { self == .unrated }
        var isDeleted: Bool { self == .deleted }
    }

    /// Wybrane pozycje skali. **Pusty zbiór znaczy „bez zawężania"**, nie
    /// „nic" — inaczej odznaczenie ostatniej pozycji kasowałoby cały widok.
    @Published var grades: Set<Grade> = {
        let stored = UserDefaults.standard.array(forKey: "library.grades") as? [Int] ?? []
        return Set(stored.compactMap(Grade.init(rawValue:)))
    }() {
        didSet {
            UserDefaults.standard.set(grades.map(\.rawValue).sorted(), forKey: "library.grades")
        }
    }

    /// Cecha policzona przez system, użyta jako warunek.
    ///
    /// Nie jest oceną i niczego nie waży — to inne pytanie do tego samego
    /// archiwum. Zero w pomiarze znaczy „nie policzono", a nie „beznadziejne",
    /// więc nigdzie nie liczy się jako wynik najgorszy.
    /// `rawValue` bierze się z nazwy przypadku i **nigdy nie jest tekstem dla
    /// człowieka** — bo trafia do ustawień i do klucza pamięci podręcznej.
    /// Napis pokazywany na ekranie mieszka osobno, w `label`, i wolno go
    /// tłumaczyć bez konsekwencji. Miary nauczyły się tego wcześniej
    /// (patrz `Measure.code`); te dwa wyliczenia zostały z polskimi napisami
    /// w roli klucza i przy tłumaczeniu skasowałyby ludziom zapisane wybory.
    enum Feature: String, CaseIterable, Identifiable {
        case any, blurry, dark, eyes, screenshots
        var id: String { rawValue }

        /// Czy warunek jest ciągły — tylko wtedy próg ma sens.
        var isContinuous: Bool { self == .blurry || self == .dark }

        var label: String {
            switch self {
            case .any: String(localized: "no condition")
            case .blurry: String(localized: "blurry")
            case .dark: String(localized: "badly exposed")
            case .eyes: String(localized: "closed eyes")
            case .screenshots: String(localized: "screenshots")
            }
        }

        var hint: String {
            switch self {
            case .any: String(localized: "everything that passed the other conditions")
            case .blurry: String(localized: "lower = more blurred")
            case .dark: String(localized: "lower = worse exposed")
            case .eyes: String(localized: "someone in the photo has their eyes closed")
            case .screenshots: String(localized: "recognised by the system")
            }
        }
    }

    /// Porządek zbioru roboczego — czyli to, co znaczy „następne zdjęcie".
    ///
    /// Osobny od warunku celowo: chcieć obejrzeć same zrzuty ekranu po kolei
    /// to co innego niż obejrzeć całe archiwum od najbardziej poruszonych.
    enum Order: String, CaseIterable, Identifiable {
        case library, day, blurry, dark, eyes, best, worst
        /// Od najgorszych wedle miary wybranej w panelu cech. Bez wybranej
        /// miary zachowuje się jak kolejność biblioteki.
        case measure
        var id: String { rawValue }

        var label: String {
            switch self {
            case .library: String(localized: "as in library")
            case .day: String(localized: "by day")
            case .blurry: String(localized: "blurriest first")
            case .dark: String(localized: "darkest first")
            case .eyes: String(localized: "closed eyes first")
            case .best: String(localized: "best first")
            case .worst: String(localized: "worst first")
            case .measure: String(localized: "by chosen measure")
            }
        }

        /// Czy ta kolejność dzieli siatkę na nagłówki.
        ///
        /// Grupowanie **nie jest osobną osią** — to pozycja tej samej listy,
        /// wykluczająca się z pozostałymi. Gdyby było osią, trzeba by
        /// odpowiedzieć, co znaczy „następne zdjęcie" przy grupowaniu po dniu
        /// i sortowaniu po poruszeniu naraz: kolejne w dniu czy kolejny dzień.
        /// Tak kolejka zostaje płaska, a nagłówki są w niej podziałami.
        var isGrouped: Bool { self == .day }
    }

    @Published var feature: Feature = Feature(rawValue:
        UserDefaults.standard.string(forKey: "library.feature") ?? ""
    ) ?? .any {
        didSet {
            UserDefaults.standard.set(feature.rawValue, forKey: "library.feature")
            // Cecha i miara to jedna lista wyboru, tylko w dwóch miejscach
            // panelu — więc wybranie jednej zdejmuje drugą.
            if feature != .any { measure = nil }
        }
    }

    /// Miara ze spisu `Measure.all`, wybrana jako warunek. Kod, nie nazwa —
    /// nazwa zmieni się przy tłumaczeniu, kod nie zmienia się nigdy.
    @Published var measure: UInt8? = {
        let raw = UserDefaults.standard.object(forKey: "library.measure") as? Int ?? -1
        return raw >= 0 ? UInt8(raw) : nil
    }() {
        didSet {
            UserDefaults.standard.set(measure.map(Int.init) ?? -1, forKey: "library.measure")
            if measure != nil { feature = .any }
        }
    }

    /// Przedziały ustawione ręcznie, osobno dla każdej miary.
    ///
    /// **Przedział, nie próg z kierunkiem.** Przy miarach znakowanych nie
    /// wiadomo z góry, która strona jest ciekawa — ikoniczność ma zakres od −2
    /// do 1 i pytanie „mniejsze czy większe od progu" nie ma oczywistej
    /// odpowiedzi. Dwa znaczniki obejmują oba przypadki bez pytania: „poniżej x"
    /// to lewy znacznik na krańcu, „powyżej x" to prawy, a przy okazji da się
    /// wziąć środek skali. Miara bez wpisu używa najgorszej dziesiątej części.
    @Published var measureRanges: [UInt8: ClosedRange<Double>] = {
        let stored = UserDefaults.standard.dictionary(forKey: "library.measureRanges") as? [String: [Double]] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, pair in
            guard let code = UInt8(key), pair.count == 2, pair[0] <= pair[1] else { return nil }
            return (code, pair[0]...pair[1])
        })
    }() {
        didSet {
            let stored = Dictionary(uniqueKeysWithValues: measureRanges.map {
                (String($0.key), [$0.value.lowerBound, $0.value.upperBound])
            })
            UserDefaults.standard.set(stored, forKey: "library.measureRanges")
        }
    }

    var activeMeasure: Measure? { measure.flatMap { Measure.byCode[$0] } }

    func range(for measure: Measure, in features: FeatureIndex) -> ClosedRange<Double> {
        if let chosen = measureRanges[measure.code] { return chosen }
        guard let stat = features.stats[measure.code] else { return 0...0 }
        return stat.defaultRange(higherIsBetter: measure.higherIsBetter)
    }

    /// Czy zdjęcie mieści się w przedziale. Brak pomiaru to nie wynik —
    /// zdjęcie niezbadane nie trafia do żadnej miary.
    func carries(_ row: FeatureIndex.Row?, slot: Int, measure: Measure,
                 range: ClosedRange<Double>) -> Bool {
        guard let value = row?.value(at: slot) else { return false }
        switch measure.kind {
        case .flag: return value > 0.5
        case .continuous: return range.contains(Double(value))
        }
    }

    @Published var order: Order = Order(rawValue:
        UserDefaults.standard.string(forKey: "library.order") ?? ""
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
        // Pamięć podręczna obejmuje **wszystko poza oceną**: rok, szukanie,
        // cechę, miarę i porządek. To one wymagają przefiltrowania 26 tysięcy
        // pozycji i posortowania ich, więc to one muszą być policzone raz.
        let key = "\(baseStamp)|\(feature.rawValue)|\(threshold)|\(order.rawValue)"
            + "|\(measure.map(String.init) ?? "-")|\(activeMeasure.map { range(for: $0, in: features).description } ?? "")"
            + "|\(reviews.count)|\(features.revision)"

        if key != cacheKey {
            var result = base
            if feature != .any {
                result = result.filter { carries(features[$0.localIdentifier]) }
            }
            if let active = activeMeasure, let slot = features.slots[active.code] {
                let limit = range(for: active, in: features)
                result = result.filter {
                    carries(features[$0.localIdentifier], slot: slot, measure: active, range: limit)
                }
            }
            cached = sorted(result, reviews: reviews, features: features)
            cacheKey = key
        }

        // Ocena **poza pamięcią podręczną**, nakładana przy każdym wywołaniu.
        //
        // Wcześniej siedziała w kluczu razem z resztą, żeby zbiór nie
        // przestawiał się pod palcem przy każdej ocenie. Chroniło to przed
        // przesortowaniem, ale przy okazji zatrzymywało w widoku zdjęcia, które
        // przestały spełniać warunek: przy filtrze „od 1 do 3" wyzerowane
        // zdjęcie zostawało na ekranie. Widok kłamał o tym, co pokazuje.
        //
        // Rozdzielone działa tak, jak trzeba: zdjęcie **znika**, gdy przestaje
        // pasować, ale reszta **nie zmienia kolejności**, bo posortowana
        // tablica leży nietknięta w pamięci podręcznej. Filtrowanie gotowej
        // tablicy to jeden przelot ze sprawdzeniem w słowniku — tanio, nawet
        // kilka razy na odrysowanie.
        guard !grades.isEmpty else { return cached }
        return cached.filter { accepts(reviews[$0.localIdentifier]) }
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
        case .measure:
            guard let active = activeMeasure, let slot = features.slots[active.code] else {
                return assets
            }
            // Najgorsze pierwsze, brak pomiaru na końcu.
            return assets.sorted { a, b in
                let x = features[a.localIdentifier]?.value(at: slot)
                let y = features[b.localIdentifier]?.value(at: slot)
                switch (x, y) {
                case (nil, nil), (nil, _): return false
                case (_, nil): return true
                case (let x?, let y?): return active.higherIsBetter ? x < y : x > y
                }
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
        /// Ile zdjęć leży na każdej pozycji skali.
        var grades: [Grade: Int] = [:]
        var feature: [Feature: Int] = [:]
        /// Ile zdjęć dałaby każda miara ze spisu przy jej bieżącym progu.
        var measures: [UInt8: Int] = [:]
        var total = 0
    }

    func tally(_ reviews: [String: Review], features: FeatureIndex) -> Tally {
        var result = Tally()

        // Progi i pozycje policzone raz, nie przy każdym zdjęciu.
        let checks: [(Measure, Int, ClosedRange<Double>)] = features.available.compactMap { measure in
            guard let slot = features.slots[measure.code] else { return nil }
            return (measure, slot, range(for: measure, in: features))
        }
        let active = activeMeasure.flatMap { measure in
            checks.first { $0.0.code == measure.code }
        }

        for asset in base {
            let id = asset.localIdentifier
            let review = reviews[id]
            let row = features[id]

            // Cecha i miara wykluczają się, więc warunek „z listy cech" to
            // jedno albo drugie — nigdy oba naraz.
            var passesCondition = carries(row, as: feature)
            if let active {
                passesCondition = passesCondition
                    && carries(row, slot: active.1, measure: active.0, range: active.2)
            }
            let passesStanding = accepts(review)

            if passesCondition {
                // Licznik pozycji skali liczy się **bez** bieżącego wyboru na
                // skali, inaczej każda pozycja poza wybraną pokazywałaby zero
                // i kontrolka przestawałaby cokolwiek mówić.
                result.grades[grade(of: review), default: 0] += 1
            }
            if passesStanding {
                for value in Feature.allCases where carries(row, as: value) {
                    result.feature[value, default: 0] += 1
                }
                if row != nil {
                    for (measure, slot, limit) in checks
                    where carries(row, slot: slot, measure: measure, range: limit) {
                        result.measures[measure.code, default: 0] += 1
                    }
                }
            }
            if passesCondition && passesStanding { result.total += 1 }
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
        case .measure:
            guard let active = activeMeasure, active.kind == .continuous,
                  let slot = features.slots[active.code],
                  let value = row.value(at: slot) else { return nil }
            return String(format: "%.2f", value)
        case .sharpness: return row.sharpness > 0 ? String(format: "%.2f", row.sharpness) : nil
        case .exposure: return row.exposure > 0 ? String(format: "%.2f", row.exposure) : nil
        case .eyes:
            guard row.eyesClosed > 0 else { return nil }
            return "\(row.eyesClosed) of \(max(row.faces, row.eyesClosed))"
        case .screenshot: return row.isScreenshot ? "screenshot" : nil
        }
    }

    /// Miara, która jest akurat w grze. Warunek ma pierwszeństwo przed
    /// porządkiem: skoro oglądam same zrzuty, to podpis ma mówić o zrzutach.
    enum Axis { case none, sharpness, exposure, eyes, screenshot, measure }

    var axis: Axis {
        if measure != nil { return .measure }
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

    /// Czy zdjęcie przechodzi warunek oceny — skalę i znacznik naraz.
    func accepts(_ review: Review?) -> Bool {
        guard !grades.isEmpty else { return true }
        return grades.contains(grade(of: review))
    }

    /// Pozycja skali, na której leży zdjęcie. Brak oceny to osobna pozycja,
    /// a nie zero: zero jest oceną najniższą, brak jest brakiem punktu.
    func grade(of review: Review?) -> Grade {
        // Oznaczenie wygrywa z oceną: decyzja o losie zdjęcia jest ostatnia
        // i nie ma sensu pytać, ile gwiazdek ma coś, co idzie do kosza.
        if review?.markedForDeletion == true { return .deleted }
        guard let review, review.isRated else { return .unrated }
        return Grade(rawValue: review.stars) ?? .zero
    }

    // MARK: - Szukanie

    var isActive: Bool {
        fromYear > 0 || toYear < 9999 || !grades.isEmpty || !query.isEmpty
            || feature != .any || order != .library || measure != nil
    }

    func clear() {
        query = ""
        grades = []
        feature = .any
        measure = nil
        order = .library
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
            self.searchNote = failure ?? (found.isEmpty ? "Nothing matches: \(text)" : nil)
            self.isSearching = false
            self.rebuild()
        }
        #else
        // Indeks wyszukiwania Apple leży w pakiecie biblioteki na dysku Maca.
        // Na telefonie nie ma go skąd wziąć — PhotoKit nie udostępnia ani
        // etykiet, ani tekstu, a przepisywanie 285 tysięcy przypisań przez
        // albumy byłoby lekarstwem gorszym od choroby.
        matches = nil
        searchNote = "Content search works on the Mac only — the phone has no such index."
        rebuild()
        #endif
    }
}
