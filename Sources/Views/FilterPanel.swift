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
    @Query private var reviews: [Review]
    @Environment(\.dismiss) private var dismiss

    private var byID: [String: Review] {
        Dictionary(reviews.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var matching: Int { filters.apply(byID).count }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            Form {
                Section("Szukaj w treści") { searchField; searchNote }
                Section("Ocena") { standingPicker; starRange }
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
                    if !library.years.isEmpty {
                        group("Zakres lat") { yearPickers }
                    }
                }
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

    // MARK: - Lata

    @ViewBuilder
    private var yearPickers: some View {
        Picker("od", selection: $filters.fromYear) {
            Text("od początku").tag(0)
            ForEach(library.years, id: \.year) { entry in
                Text("\(String(entry.year))  ·  \(entry.count)").tag(entry.year)
            }
        }
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
