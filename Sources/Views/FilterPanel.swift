import Photos
import SwiftData
import SwiftUI

/// Wszystkie warunki w jednym miejscu — na macOS **na stałe przy krawędzi
/// okna**, na telefonie w arkuszu.
///
/// Filtr przestał być czynnością („otwórz, wybierz, zamknij") i stał się
/// widokiem. Powód jest jeden i jest nim licznik: dopóki panel trzeba było
/// otworzyć, nie dało się wiedzieć, ile czego jest, bez przerywania pracy.
///
/// Warunki są **wierszami z licznikami**, nie przełącznikami. To rozwiązuje
/// trzy rzeczy naraz:
///
/// - Każdy wiersz mówi, ile zdjęć dałby, **zanim** go klikniesz. Poprzednia
///   wersja miała jeden licznik na dole i pokazywała wynik po wyborze, więc
///   zawężanie było strzelaniem w ciemno.
/// - Wiersze rosną **w dół**, a pion jest tani i przewijalny. Segmentowany
///   przełącznik rósł w bok i przy czterech pozycjach ucinał ostatnią
///   o kilka punktów — a liczba kategorii nie jest zamknięta i długość słów
///   zmieni się przy pierwszym tłumaczeniu.
/// - Nie ma tu ani jednej sztywnej szerokości, więc nie ma czego przepełnić.
struct FilterPanel: View {
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var filters: Filters
    @ObservedObject var features: FeatureIndex

    /// Panel liczy tylko po stanie oceny — puste rekordy niosące same cechy
    /// systemu nie zmieniają w nim nic. Patrz komentarz w `CullView`.
    @Query(filter: #Predicate<Review> { $0.isRated || $0.markedForDeletion })
    private var reviews: [Review]

    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    /// Liczniki przeliczane **raz na zmianę warunków**, nie przy odrysowaniu.
    /// Dziewięć sprawdzeń na zdjęcie razy 25 tysięcy to nic, ale nie przy
    /// każdej klatce przeciągania suwakiem.
    @State private var tally = Filters.Tally()

    private var trigger: String {
        "\(filters.baseStamp)|\(filters.standing.rawValue)|\(filters.feature.rawValue)"
        + "|\(filters.threshold)|\(reviews.count)|\(features.revision)"
    }

    private func recount() {
        let index = Dictionary(
            reviews.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a }
        )
        tally = filters.tally(index, features: features)
    }

    var body: some View {
        content
            .task(id: trigger) {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                recount()
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        NavigationStack {
            ScrollView { sections.padding(16) }
                .navigationTitle("Filtr")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("wyczyść") { filters.clear() }
                            .disabled(!filters.isActive)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Gotowe") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) { footer }
        }
        .presentationDetents([.medium, .large])
        #else
        VStack(spacing: 0) {
            ScrollView { sections.padding(14) }
            Divider()
            footer
        }
        #endif
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Szukaj w treści") { searchField; searchNote }
            group("Ocena") { standingRows; starRange }
            group("Cechy systemu") { featureRows; thresholdSlider; featureNote }
            group("Kolejność") { orderRows }
            if !library.years.isEmpty {
                group("Zakres lat") { yearPickers }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            content()
        }
    }

    // MARK: - Wiersz

    /// Jeden warunek. Znacznik po lewej, nazwa w środku, liczba po prawej.
    ///
    /// Nazwa ma prawo zająć dwie linie — to jedyne miejsce, w którym długie
    /// tłumaczenie może się rozlać, i rozleje się w dół, gdzie nie boli.
    /// Liczba nie zawija się nigdy, bo cyfry są wszędzie tak samo szerokie.
    @ViewBuilder
    private func row(
        _ title: String, count: Int?, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
                Text(title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(isOn ? .primary : .secondary)
                Spacer(minLength: 10)
                if let count {
                    Text(count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(count == 0 ? .tertiary : .secondary)
                        .layoutPriority(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .padding(.vertical, 1)
        #else
        .padding(.vertical, 3)
        #endif
    }

    // MARK: - Ocena

    private var standingRows: some View {
        ForEach(Filters.Standing.allCases) { value in
            row(value.rawValue,
                count: tally.standing[value] ?? 0,
                isOn: filters.standing == value) { filters.standing = value }
        }
    }

    /// Gwiazdki mają sens wyłącznie wśród ocenionych: dla nieocenionych nie ma
    /// czego zawężać, a „do usunięcia" jest znacznikiem, nie punktem na skali.
    ///
    /// Każda gwiazdka to **osobny przełącznik**, nie koniec zakresu. Można
    /// zapalić samą trójkę albo trójkę i piątkę z pominięciem czwórki.
    /// Poprzednia wersja trzymała zakres i musiała udawać, że stuknięcie raz
    /// zwija, a raz rozciąga — regułę tę dało się poznać wyłącznie przez
    /// zaskoczenie.
    @ViewBuilder
    private var starRange: some View {
        if filters.standing == .rated {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(0...5, id: \.self) { value in starCell(value) }
                }
                Text(starSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    /// Jedna pozycja skali: symbol i pod nim liczba zdjęć, które ją mają.
    /// Zero dostaje przekreśloną gwiazdkę — to nie brak oceny, tylko ocena
    /// najniższa z możliwych.
    private func starCell(_ value: Int) -> some View {
        let isOn = filters.stars.contains(value)
        let symbol = value == 0
            ? (isOn ? "star.slash.fill" : "star.slash")
            : (isOn ? "star.fill" : "star")

        return VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(isOn ? Color.yellow : Color.secondary.opacity(0.35))
            Text((tally.stars[value] ?? 0).formatted())
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(isOn ? .secondary : .tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn { filters.stars.remove(value) } else { filters.stars.insert(value) }
        }
    }

    private var starSummary: String {
        guard !filters.stars.isEmpty else {
            return "Wszystkie oceny. Stuknij gwiazdkę, żeby zawęzić."
        }
        let chosen = filters.stars.sorted().map(String.init).joined(separator: ", ")
        return "Tylko: \(chosen). Stuknij ponownie, żeby odznaczyć."
    }

    // MARK: - Cechy

    private var featureRows: some View {
        ForEach(Filters.Feature.allCases) { value in
            // „Bez warunku" też ma licznik — to jest liczba, do której
            // wracasz, i bez niej nie widać, ile kosztuje każdy warunek.
            row(value.rawValue,
                count: tally.feature[value] ?? 0,
                isOn: filters.feature == value) { filters.feature = value }
        }
    }

    /// Próg ma sens wyłącznie przy warunkach ciągłych. Przy „zrzutach ekranu"
    /// nie ma czego przesuwać — zdjęcie albo jest zrzutem, albo nie jest.
    @ViewBuilder
    private var thresholdSlider: some View {
        if filters.feature.isContinuous {
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: $filters.threshold, in: 0.1...1.0) { Text("próg") }
                    .labelsHidden()
                Text(String(format: "poniżej %.2f", filters.threshold))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var featureNote: some View {
        if features.isEmpty {
            #if os(macOS)
            note("Nie wczytano jeszcze cech. Przycisk w belce narzędzi — wymaga Pełnego dostępu do dysku.",
                 colour: .orange)
            #else
            note("Nie wczytano jeszcze cech. Liczy je Mac i przyjeżdżają tu synchronizacją.",
                 colour: .orange)
            #endif
        } else {
            note(filters.feature.hint, colour: .secondary)
        }
    }

    // MARK: - Kolejność

    /// Porządek zbioru to nie ozdoba: decyduje, co znaczy „następne zdjęcie"
    /// po geście w ocenianiu. Bez licznika, bo kolejność niczego nie odsiewa.
    private var orderRows: some View {
        ForEach(Filters.Order.allCases) { value in
            row(value.rawValue, count: nil,
                isOn: filters.order == value) { filters.order = value }
        }
    }

    // MARK: - Szukanie

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("las, tablica, Kraków…", text: $filters.query)
                #if os(iOS)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #else
                .textFieldStyle(.roundedBorder)
                #endif
            if filters.isSearching {
                ProgressView().controlSize(.small)
            } else if !filters.query.isEmpty {
                Button { filters.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var searchNote: some View {
        if let text = filters.searchNote {
            note(text, colour: .orange)
        } else {
            note("Etykiety scen, imiona osób, nazwy miejsc i tekst ze zdjęć.", colour: .secondary)
        }
    }

    private func note(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Lata

    /// Etykieta nad polem, nie obok niego. Przy wąskiej kolumnie i dowolnym
    /// tłumaczeniu to jedyny układ, który nie ma jak się nie zmieścić.
    @ViewBuilder
    private var yearPickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            labelled("od") {
                Picker("od", selection: $filters.fromYear) {
                    Text("od początku").tag(0)
                    ForEach(library.years, id: \.year) { entry in
                        Text("\(String(entry.year))  ·  \(entry.count)").tag(entry.year)
                    }
                }
            }
            labelled("do") {
                Picker("do", selection: $filters.toYear) {
                    Text("do końca").tag(9999)
                    ForEach(library.years.reversed(), id: \.year) { entry in
                        Text(String(entry.year)).tag(entry.year)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func labelled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Wynik

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Pasuje").foregroundStyle(.secondary)
            Text("\(tally.total)")
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(tally.total == 0 ? .orange : .primary)
            Text("z \(library.assets.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            #if os(macOS)
            Button("wyczyść") { filters.clear() }
                .disabled(!filters.isActive)
            #endif
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
