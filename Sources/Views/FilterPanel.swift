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

    /// Miary przypięte na wierzch, w kolejności przypięcia.
    ///
    /// **Ręcznie, nie samouczone.** Lista, po której chodzi się z pamięci, nie
    /// może się przestawiać sama wedle tego, czego ostatnio używano — to znany
    /// sposób na zepsucie dobrego menu. Co ma być na wierzchu, to fakt
    /// o człowieku i o zadaniu, nie o bazie.
    @AppStorage("features.pinned") private var pinnedRaw = ""
    @AppStorage("features.expanded") private var expanded = false

    /// Miary, o których użytkownik już wie. Nowa miara z sygnałem, której tu
    /// nie ma, dostaje kartę zamiast wejść do listy po cichu.
    @AppStorage("features.known") private var knownRaw = ""
    @State private var measureQuery = ""

    private var pinned: [UInt8] {
        pinnedRaw.split(separator: ",").compactMap { UInt8($0) }
    }

    private var trigger: String {
        "\(filters.baseStamp)|\(filters.grades.map(\.rawValue).sorted())|\(filters.onlyMarked)|\(filters.feature.rawValue)"
        + "|\(filters.threshold)|\(reviews.count)|\(features.revision)"
        + "|\(filters.measure.map(String.init) ?? "-")|\(filters.measureRanges.description)"

    }

    private func recount() {
        let index = Dictionary(
            reviews.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a }
        )
        tally = filters.tally(index, features: features)
    }

    var body: some View {
        content
            .task(id: features.revision) {
                guard knownRaw.isEmpty, !features.available.isEmpty else { return }
                knownRaw = features.available.map { String($0.code) }.joined(separator: ",")
            }
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
            group("Ocena") { gradeScale; markedRow }
            group("Cechy systemu") {
                featureRows
                thresholdSlider
                pinnedRows
                measureSlider
                rarelyUsed
                newcomers
                featureNote
            }
            #if os(iOS)
            // Na Macu kolejność siedzi na belce nad siatką — to nie jest
            // warunek, tylko sposób czytania zbioru. Na telefonie belki nie ma.
            group("Kolejność") { orderRows }
            #endif
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

    /// Cała ocena w jednym rzędzie: brak oceny, zero i pięć gwiazdek.
    ///
    /// Zastąpiło to cztery wiersze stanu plus skalę chowaną pod „ocenionymi".
    /// Ten sam wybór da się wyrazić zaznaczeniem: nic to wszystkie, `brak` to
    /// nieocenione, komplet gwiazdek to ocenione. A dochodzą przedziały,
    /// których tamten układ nie umiał: sam dół skali albo oceny bez dna.
    private var gradeScale: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Filters.Grade.allCases) { gradeCell($0) }
            }
            Text(gradeSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Jedna pozycja skali: symbol i pod nim liczba zdjęć.
    private func gradeCell(_ grade: Filters.Grade) -> some View {
        let isOn = filters.grades.contains(grade)
        let symbol: String
        switch grade {
        // Brak oceny to przekreślone kółko, nie gwiazdka — bo to nie jest
        // punkt na skali, tylko jego brak. Zero dostaje gwiazdkę przekreśloną:
        // ocena najniższa z możliwych, czyli dno, na które wypycha się zdjęcia
        // przeznaczone do skasowania.
        case .unrated: symbol = isOn ? "circle.slash.fill" : "circle.slash"
        case .zero: symbol = isOn ? "star.slash.fill" : "star.slash"
        default: symbol = isOn ? "star.fill" : "star"
        }

        return VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(isOn ? (grade.isUnrated ? Color.accentColor : Color.yellow)
                                      : Color.secondary.opacity(0.35))
            Text((tally.grades[grade] ?? 0).formatted())
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(isOn ? .secondary : .tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn { filters.grades.remove(grade) } else { filters.grades.insert(grade) }
        }
    }

    private var gradeSummary: String {
        guard !filters.grades.isEmpty else {
            return "Wszystkie zdjęcia. Stuknij pozycję, żeby zawęzić."
        }
        let sorted = filters.grades.sorted { $0.rawValue < $1.rawValue }
        let names = sorted.map { $0.isUnrated ? "bez oceny" : String($0.rawValue) }
        return "Tylko: \(names.joined(separator: ", ")). Stuknij ponownie, żeby odznaczyć."
    }

    /// Znacznik „do usunięcia" osobno, bo to nie ocena, tylko decyzja o losie
    /// zdjęcia — i zwykle towarzyszy jakiejś ocenie, zamiast ją zastępować.
    private var markedRow: some View {
        row("do usunięcia",
            count: tally.marked,
            isOn: filters.onlyMarked) { filters.onlyMarked.toggle() }
            .padding(.top, 2)
    }

    // MARK: - Cechy

    private var featureRows: some View {
        ForEach(Filters.Feature.allCases) { value in
            // „Bez warunku" też ma licznik — to jest liczba, do której
            // wracasz, i bez niej nie widać, ile kosztuje każdy warunek.
            // Cechy i miary są jedną listą wyboru, więc „bez warunku" świeci
            // tylko wtedy, gdy nie jest wybrana ani cecha, ani miara.
            row(value.rawValue,
                count: tally.feature[value] ?? 0,
                isOn: filters.feature == value && (value != .any || filters.measure == nil)) {
                filters.feature = value
                if value == .any { filters.measure = nil }
            }
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

    // MARK: - Miary ze spisu

    private func togglePin(_ code: UInt8) {
        var list = pinned
        if let index = list.firstIndex(of: code) { list.remove(at: index) } else { list.append(code) }
        pinnedRaw = list.map(String.init).joined(separator: ",")
    }

    @ViewBuilder
    private func measureRow(_ measure: Measure) -> some View {
        row(measure.label,
            count: tally.measures[measure.code] ?? 0,
            isOn: filters.measure == measure.code) {
            filters.measure = filters.measure == measure.code ? nil : measure.code
        }
        .contextMenu {
            Button(pinned.contains(measure.code) ? "odepnij" : "przypnij na wierzch") {
                togglePin(measure.code)
            }
        }
    }

    /// Przypięte miary stoją **pod** stałymi cechami, a nad roletą.
    @ViewBuilder
    private var pinnedRows: some View {
        let shown = pinned.compactMap { code in features.available.first { $0.code == code } }
        ForEach(shown) { measureRow($0) }
    }

    /// Przedział dla wybranej miary ciągłej — dwa znaczniki nad histogramem.
    ///
    /// Końce pochodzą z **pomiaru tej biblioteki**, nie z zakresu 0–1: przechył
    /// kadru mieści się tu między −0,22 a 0,08, a ikoniczność między −2 a 1.
    /// Przy takich miarach zwykły próg zmuszał do zgadywania, w którą stronę
    /// odsiewa; przedział o to nie pyta.
    @ViewBuilder
    private var measureSlider: some View {
        if let active = filters.activeMeasure, active.kind == .continuous,
           let stat = features.stats[active.code], stat.max > stat.min {
            let bounds = Double(stat.min)...Double(stat.max)
            let binding = Binding<ClosedRange<Double>>(
                get: { filters.range(for: active, in: features) },
                set: { filters.measureRanges[active.code] = $0 }
            )
            let current = binding.wrappedValue

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    // Nazwa miary **przy suwaku**, nie tylko przy wierszu. Suwak
                    // stoi pod stałymi cechami, a wybrana miara bywa głęboko
                    // w rolecie, poza ekranem — sam przedział liczb nie mówi,
                    // czego dotyczy.
                    VStack(alignment: .leading, spacing: 0) {
                        Text(active.label)
                            .font(.caption.weight(.semibold))
                        Text("od \(String(format: "%.2f", current.lowerBound)) do \(String(format: "%.2f", current.upperBound))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 6)
                    Menu {
                        Button("najgorsza dziesiąta część") {
                            filters.measureRanges[active.code] = nil
                        }
                        Button("najlepsza dziesiąta część") {
                            let worst = stat.defaultRange(higherIsBetter: active.higherIsBetter)
                            let mirrored = active.higherIsBetter
                                ? mirror(worst.upperBound, in: bounds, stat: stat, higherIsBetter: true)
                                : mirror(worst.lowerBound, in: bounds, stat: stat, higherIsBetter: false)
                            filters.measureRanges[active.code] = mirrored
                        }
                        Button("cały zakres") {
                            filters.measureRanges[active.code] = bounds
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("szybkie przedziały")
                }

                RangeSlider(range: binding, bounds: bounds, histogram: stat.histogram)

                HStack {
                    Text(String(format: "%.2f", stat.min))
                    Spacer()
                    Text(active.higherIsBetter ? "← gorzej · lepiej →" : "← lepiej · gorzej →")
                    Spacer()
                    Text(String(format: "%.2f", stat.max))
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
    }

    /// Najlepsza dziesiąta część jako lustro najgorszej: tyle samo zdjęć,
    /// z drugiego końca rozkładu. Liczone z histogramu, bo sam indeks nie niesie
    /// już posortowanych wartości.
    private func mirror(_ edge: Double, in bounds: ClosedRange<Double>,
                        stat: FeatureIndex.Stat, higherIsBetter: Bool) -> ClosedRange<Double> {
        let total = stat.histogram.reduce(0, +)
        guard total > 0 else { return bounds }
        let target = max(1, total / 10)
        let step = (bounds.upperBound - bounds.lowerBound) / Double(stat.histogram.count)
        var sum = 0
        if higherIsBetter {
            for index in stat.histogram.indices.reversed() {
                sum += stat.histogram[index]
                if sum >= target {
                    return (bounds.lowerBound + Double(index) * step)...bounds.upperBound
                }
            }
        } else {
            for index in stat.histogram.indices {
                sum += stat.histogram[index]
                if sum >= target {
                    return bounds.lowerBound...(bounds.lowerBound + Double(index + 1) * step)
                }
            }
        }
        return bounds
    }

    /// Roleta z resztą miar. Startuje zwinięta; przy trzydziestu pozycjach
    /// ma własne szukanie i dzieli się wedle tego, **czego miara dotyczy** —
    /// bo grupy odpowiadają różnym zadaniom: ocenianiu jakości, sprzątaniu
    /// i szukaniu konkretnego materiału.
    @ViewBuilder
    private var rarelyUsed: some View {
        let rest = features.available.filter { !pinned.contains($0.code) }
        if !rest.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("rzadziej używane")
                    Spacer(minLength: 8)
                    Text("\(rest.count)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            if expanded {
                let query = measureQuery.trimmingCharacters(in: .whitespaces).lowercased()
                let matching = query.isEmpty ? rest : rest.filter { $0.label.lowercased().contains(query) }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("szukaj miary", text: $measureQuery)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    Text("\(matching.count) z \(rest.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)

                ForEach(Measure.Group.allCases, id: \.self) { group in
                    let items = matching.filter { $0.group == group }
                    if !items.isEmpty {
                        Text(group.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                        ForEach(items) { measureRow($0) }
                    }
                }

                Text("Prawy przycisk na wierszu przypina miarę na wierzch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    /// Karta nowo znalezionej miary.
    ///
    /// Spis jest pisany ręcznie, ale kolumny potrafią się **zapalić** — funkcja
    /// systemu, która rok temu była pusta, zaczyna być liczona. Taka miara nie
    /// wchodzi do listy po cichu i nie zmienia sama filtru: najpierw mówi, że
    /// jest. Przy pierwszym wczytaniu wszystkie są „znane", żeby nie zasypać
    /// panelu trzydziestoma kartami naraz.
    @ViewBuilder
    private var newcomers: some View {
        let known = Set(knownRaw.split(separator: ",").compactMap { UInt8($0) })
        let fresh = knownRaw.isEmpty ? [] : features.available.filter { !known.contains($0.code) }
        if let first = fresh.first {
            VStack(alignment: .leading, spacing: 6) {
                Text("system zaczął liczyć **\(first.label)** · \(features.stats[first.code]?.count ?? 0) zdjęć ma pomiar")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("pokaż") {
                        filters.measure = first.code
                        rememberKnown(first.code)
                    }
                    Button("ukryj") { rememberKnown(first.code) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(.top, 6)
        }
    }

    private func rememberKnown(_ code: UInt8) {
        var known = Set(knownRaw.split(separator: ",").compactMap { UInt8($0) })
        known.insert(code)
        knownRaw = known.sorted().map(String.init).joined(separator: ",")
    }

    // MARK: - Kolejność    // MARK: - Kolejność

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
