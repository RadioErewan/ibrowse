import Photos
import SwiftData
import SwiftUI

/// Dedykowany widok filtrowania — wszystkie warunki w jednym miejscu.
///
/// Wcześniej rok wybierało się w pasku narzędzi, a stan oceny w segmentowanym
/// przełączniku nad zdjęciem. Dwa miejsca na jedno pytanie „co teraz oglądam",
/// przy czym drugie z nich znikało po przejściu do siatki.
///
/// Licznik jest tu najważniejszy: pokazuje wynik **zanim** zamkniesz okno. Bez
/// niego zawężanie zakresu to strzelanie w ciemno i wychodzenie za każdym
/// razem, żeby sprawdzić, czy cokolwiek zostało.
///
/// Układ jest inny na każdej platformie. Na telefonie `Form` w arkuszu jest
/// naturalny. Na Macu ten sam `Form` w popoverze wyszedł przezroczysty —
/// styl zgrupowany nie maluje własnego tła, więc przez panel przebijała
/// siatka zdjęć. Dlatego Mac dostaje zwykły stos z jawnym tłem.
struct FilterPanel: View {
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var filters: Filters

    /// Cechy policzone przez system. Były kiedyś osobną zakładką z własnym
    /// zbiorem — teraz są tu, obok roku i stanu oceny, bo to ten sam rodzaj
    /// pytania: „co teraz oglądam".
    @ObservedObject var features: FeatureIndex
    /// Panel liczy tylko, ile zdjęć pasuje do warunków — a te dotyczą stanu
    /// oceny. Patrz komentarz w `CullView`.
    @Query(filter: #Predicate<Review> { $0.isRated || $0.markedForDeletion })
    private var reviews: [Review]
    @Environment(\.dismiss) private var dismiss

    private var byID: [String: Review] {
        Dictionary(reviews.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var matching: Int { filters.apply(byID, features: features).count }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            Form {
                Section("Szukaj w treści") { searchField; searchNote }
                Section("Ocena") { standingPicker; starRange }
                Section("Cechy systemu") { featurePicker; thresholdSlider; featureNote }
                Section("Kolejność") { orderPicker }
                if !library.years.isEmpty {
                    Section("Zakres lat") { yearPickers }
                }
                Section { tally }
            }
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
        }
        .presentationDetents([.medium, .large])
        #else
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group("Szukaj w treści") { searchField; searchNote }
                    group("Ocena") { standingPicker; starRange }
                    group("Cechy systemu") { featurePicker; thresholdSlider; featureNote }
                    group("Kolejność") { orderPicker }
                    if !library.years.isEmpty {
                        group("Zakres lat") { yearPickers }
                    }
                }
                // Twarda szerokość treści, nie sama szerokość panelu.
                // `.frame(width:)` na zewnętrznym stosie nie powstrzymuje
                // dziecka, które zażąda więcej — takie dziecko wylewa się
                // symetrycznie i znika pod krawędzią.
                .frame(width: 368, alignment: .leading)
                .padding(16)
            }

            Divider()

            HStack(spacing: 12) {
                tally
                Spacer()
                Button("wyczyść") { filters.clear() }
                    .disabled(!filters.isActive)
                Button("Gotowe") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 400)
        .frame(maxHeight: 560)
        // Popover sam nie maluje tła pod treścią — bez tego przez panel widać
        // zdjęcia z siatki i nie da się go przeczytać.
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
    #endif

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
        if let note = filters.searchNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Etykiety scen, imiona osób, nazwy miejsc i tekst ze zdjęć.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Ocena

    private var standingPicker: some View {
        Picker("stan", selection: $filters.standing) {
            ForEach(Filters.Standing.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Zakres gwiazdek ma sens wyłącznie wśród ocenionych: dla nieocenionych
    /// nie ma czego zawężać, a „do usunięcia" jest znacznikiem, nie punktem
    /// na skali.
    @ViewBuilder
    private var starRange: some View {
        if filters.standing == .rated {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { value in
                        let inRange = value >= filters.minStars && value <= filters.maxStars
                        Image(systemName: inRange ? "star.fill" : "star")
                            .foregroundStyle(inRange ? Color.yellow : Color.secondary.opacity(0.35))
                            .onTapGesture { pick(value) }
                    }
                    Spacer()
                    Text(filters.minStars == filters.maxStars
                         ? "dokładnie \(filters.minStars)"
                         : "\(filters.minStars)–\(filters.maxStars)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Stuknij gwiazdkę, żeby ustawić koniec zakresu.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Pierwsze stuknięcie zwija zakres do jednej gwiazdki, drugie go rozciąga.
    /// Dwa suwaki dawałyby to samo dwoma ruchami zamiast jednym.
    private func pick(_ value: Int) {
        if filters.minStars == filters.maxStars {
            if value < filters.minStars {
                filters.minStars = value
            } else {
                filters.maxStars = value
            }
        } else {
            filters.minStars = value
            filters.maxStars = value
        }
    }

    // MARK: - Cechy

    private var featurePicker: some View {
        Picker("cecha", selection: $filters.feature) {
            ForEach(Filters.Feature.allCases) { Text($0.rawValue).tag($0) }
        }
        #if os(macOS)
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    /// Próg ma sens wyłącznie przy warunkach ciągłych. Przy „zrzutach ekranu"
    /// nie ma czego przesuwać — to zdjęcie albo jest zrzutem, albo nie jest.
    @ViewBuilder
    private var thresholdSlider: some View {
        if filters.feature.isContinuous {
            HStack(spacing: 10) {
                Slider(value: $filters.threshold, in: 0.1...1.0) { Text("próg") }
                Text(String(format: "poniżej %.2f", filters.threshold))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var featureNote: some View {
        if features.isEmpty {
            #if os(macOS)
            Text("Nie wczytano jeszcze cech. Przycisk w belce narzędzi — wymaga Pełnego dostępu do dysku.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("Nie wczytano jeszcze cech. Liczy je Mac i przyjeżdżają tu synchronizacją.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        } else {
            Text("\(features.count) zdjęć z pomiarem · \(filters.feature.hint)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Kolejność

    /// Porządek zbioru to nie ozdoba: decyduje, co znaczy „następne zdjęcie"
    /// po geście w ocenianiu.
    private var orderPicker: some View {
        Picker("kolejność", selection: $filters.order) {
            ForEach(Filters.Order.allCases) { Text($0.rawValue).tag($0) }
        }
        #if os(macOS)
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    // MARK: - Lata

    /// Na Macu etykiety idą do własnej kolumny o **stałej** szerokości.
    ///
    /// Domyślne `Picker` z etykietą dobiera szerokość do treści, więc każdy
    /// wiersz kończył się w innym miejscu, a „od" i „do" wisiały poza wcięciem
    /// pozostałych sekcji.
    ///
    /// Pierwsza poprawka użyła `Grid` i było gorzej: `Grid` liczy szerokość
    /// z zawartości kolumn i **nie ściska się** do tego, co dostaje. Panel ma
    /// 400 punktów, a treść zażądała więcej i wylała się poza jego lewą
    /// krawędź — obcięło etykiety sekcji i „Pasuje" w stopce. Stała szerokość
    /// etykiety daje to samo wyrównanie bez tego ryzyka.
    @ViewBuilder
    private var yearPickers: some View {
        #if os(macOS)
        yearRow("od", fromPicker)
        yearRow("do", toPicker)
        #else
        fromPicker
        toPicker
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func yearRow<P: View>(_ label: String, _ picker: P) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            picker
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #endif

    private var fromPicker: some View {
        Picker("od", selection: $filters.fromYear) {
            Text("od początku").tag(0)
            ForEach(library.years, id: \.year) { entry in
                Text("\(String(entry.year))  ·  \(entry.count)").tag(entry.year)
            }
        }
    }

    private var toPicker: some View {
        Picker("do", selection: $filters.toYear) {
            Text("do końca").tag(9999)
            ForEach(library.years.reversed(), id: \.year) { entry in
                Text(String(entry.year)).tag(entry.year)
            }
        }
    }

    // MARK: - Wynik

    private var tally: some View {
        HStack(spacing: 6) {
            Text("Pasuje")
                .foregroundStyle(.secondary)
            Text("\(matching)")
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(matching == 0 ? .orange : .primary)
            Text("z \(library.assets.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
