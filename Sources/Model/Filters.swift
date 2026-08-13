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

    @Published var fromYear: Int = UserDefaults.standard.object(forKey: "library.fromYear") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(fromYear, forKey: "library.fromYear"); rebuild() }
    }
    @Published var toYear: Int = UserDefaults.standard.object(forKey: "library.toYear") as? Int ?? 9999 {
        didSet { UserDefaults.standard.set(toYear, forKey: "library.toYear"); rebuild() }
    }

    @Published var standing: Standing = .all
    @Published var minStars: Int = 1
    @Published var maxStars: Int = 5

    /// Szukanie po tym, co widzi system: etykiety scen, imiona, nazwy miejsc
    /// i słowa odczytane ze zdjęć.
    @Published var query: String = "" {
        didSet { guard query != oldValue else { return }; scheduleSearch() }
    }

    /// Zdjęcia po zakresie lat i szukaniu — bez warunku oceny.
    @Published private(set) var base: [PHAsset] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchNote: String?

    private var all: [PHAsset] = []
    /// `nil` znaczy „nie szukamy", a pusty zbiór — „szukaliśmy i nic nie ma".
    /// Bez tego rozróżnienia puste wyszukiwanie kasowałoby cały widok.
    private var matches: Set<String>?
    private var searchTask: Task<Void, Never>?

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
    }

    // MARK: - Ocena

    /// Nakładane w widoku, na już policzonej bazie.
    func apply(_ reviews: [String: Review]) -> [PHAsset] {
        guard standing != .all else { return base }
        return base.filter { accepts(reviews[$0.localIdentifier]) }
    }

    func accepts(_ review: Review?) -> Bool {
        switch standing {
        case .all:
            return true
        case .unrated:
            return review?.isRated != true
        case .rated:
            guard let review, review.isRated else { return false }
            return review.stars >= minStars && review.stars <= maxStars
        case .marked:
            return review?.markedForDeletion == true
        }
    }

    // MARK: - Szukanie

    var isActive: Bool {
        fromYear > 0 || toYear < 9999 || standing != .all || !query.isEmpty
    }

    func clear() {
        query = ""
        standing = .all
        minStars = 1
        maxStars = 5
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
