#if os(macOS)
import Photos
import SwiftUI

/// Panel boczny w trybie oceniania — wyłącznie na macOS.
///
/// Na telefonie nie ma na to miejsca i nie ma po co: przy kciuku liczy się samo
/// zdjęcie. Przy dużym ekranie odwrotnie — to tu odpowiada się na pytanie
/// „czemu ta klatka jest miękka", a odpowiedź brzmi zwykle ISO 6400 albo 1/15 s.
struct MetadataPanel: View {
    let asset: PHAsset?
    @ObservedObject var index: MetadataIndex
    /// Kliknięcie etykiety szuka jej w bibliotece. `nil`, gdy nie ma słów od
    /// eksportera — wtedy etykiety są zwykłym tekstem, bo szukanie i tak nic
    /// by nie znalazło.
    var onSearch: ((String) -> Void)? = nil
    @Environment(\.modelContext) private var context

    @State private var showingWords = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let asset {
                    identity(asset)
                    exposure
                    people
                    place
                    occasion
                    scenes
                    text
                    native(asset)
                } else {
                    Text("No photo").foregroundStyle(.secondary)
                }

                if let note = index.note {
                    Divider()
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Bez eksportera i bez oryginału na dysku techniki nie ma
                    // skąd wziąć — chyba że człowiek zgodzi się na pobranie.
                    if let asset, data.iso == nil, data.aperture == nil, data.camera == nil {
                        Button("Download original for camera details") {
                            Task { await index.loadOriginal(asset) }
                        }
                        .controlSize(.small)
                        .focusable(false)
                        .help("Keeps a copy on this Mac until the system needs the space")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: asset?.localIdentifier) { await index.load(asset, context: context) }
    }

    private var data: AssetMetadata { index.current ?? AssetMetadata() }
    private var search: ((String) -> Void)? { index.fromExporter ? onSearch : nil }

    // MARK: - Sekcje

    private func identity(_ asset: PHAsset) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(data.filename ?? "untitled")
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(2)
            if let date = asset.creationDate {
                Text(date.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Technika idzie na górę, zaraz pod nazwą, bo przy odsiewie to ona
    /// najczęściej tłumaczy, dlaczego zdjęcie jest nie do uratowania.

    @ViewBuilder
    private var exposure: some View {
        let line = AssetFacts.exposureLine(
            focalLength: data.focalLength, aperture: data.aperture,
            shutter: data.shutter, iso: data.iso
        )

        if line != nil || data.camera != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let line {
                    Text(line)
                        .font(.system(.callout, design: .monospaced))
                }
                if let camera = data.camera {
                    Text(camera).font(.caption).foregroundStyle(.secondary)
                }
                if let lens = data.lens, lens != data.camera {
                    Text(lens)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if data.flash == true {
                    Label("flash", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var people: some View {
        Section("People", values: data.people, tint: .blue, onSearch: search)
        Section("Animals", values: data.pets, tint: .brown, onSearch: search)
    }

    /// Miejsce jako jeden ciąg od punktu do kraju — tak, jak człowiek by je
    /// wymówił, a nie jako lista równorzędnych etykiet.
    @ViewBuilder
    private var place: some View {
        if !data.place.isEmpty {
            Group {
                heading("Place")
                if let onSearch = search {
                    // Każdy człon osobno: „Kraków" znajdzie całe miasto,
                    // a nie tylko ten jeden rynek.
                    FlowLayout(spacing: 0) {
                        ForEach(Array(data.place.enumerated()), id: \.offset) { position, name in
                            if position > 0 {
                                Text(" · ").font(.callout).foregroundStyle(.secondary)
                            }
                            SearchLabel(value: name, onSearch: onSearch) {
                                Text(name).font(.callout)
                            }
                        }
                    }
                } else {
                    Text(data.place.joined(separator: " · "))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var occasion: some View {
        Section("Occasion", values: data.occasion, tint: .purple, onSearch: search)
    }

    @ViewBuilder
    private var scenes: some View {
        Section("What the system sees", values: data.scenes, tint: .secondary, onSearch: search)
    }

    /// Odczytany tekst jest w indeksie rozbity na pojedyncze słowa bez
    /// kolejności, więc pokazujemy go zwinięty — jako trop, nie jako cytat.
    @ViewBuilder
    private var text: some View {
        if !data.words.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    showingWords.toggle()
                } label: {
                    Label(
                        "Text in the photo (\(data.words.count))",
                        systemImage: showingWords ? "chevron.down" : "chevron.right"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Bez fokusu klawiatury. Przycisk pojawia się tylko przy
                // zdjęciach z odczytanym tekstem, a macOS przestawiał na niego
                // fokus z oceniania: przy następnym zdjęciu znikał razem
                // z fokusem i cyfry przestawały działać — zawsze na tych
                // samych zdjęciach. Myszą klika się jak dotąd.
                .focusable(false)

                if showingWords {
                    Text(data.words.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// To, co PhotoKit wie sam — zawsze aktualne, niezależne od baz.
    private func native(_ asset: PHAsset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 10) {
                Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                    .font(.caption.monospacedDigit())
                Text(AssetFacts.megapixels(asset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if asset.isFavorite {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink)
                }
            }
            let traits = AssetFacts.traits(asset)
            if !traits.isEmpty {
                Text(traits.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Drobiazgi

    /// `LocalizedStringKey`, nie `String` — patrz komentarz przy `group()`
    /// w `FilterPanel`, ten sam błąd, ten sam powód.
    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .textCase(.uppercase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

}

/// Lista wartości jako zawijające się plakietki. Etykiet scen bywa
/// kilkanaście — w kolumnie zjadłyby cały panel.
private struct Section: View {
    let title: LocalizedStringKey
    let values: [String]
    let tint: Color
    let onSearch: ((String) -> Void)?

    init(
        _ title: LocalizedStringKey, values: [String], tint: Color,
        onSearch: ((String) -> Void)? = nil
    ) {
        self.title = title
        self.values = values
        self.tint = tint
        self.onSearch = onSearch
    }

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .textCase(.uppercase)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                FlowLayout(spacing: 4) {
                    ForEach(values, id: \.self) { value in
                        if let onSearch {
                            SearchLabel(value: value, onSearch: onSearch) { chip(value) }
                        } else {
                            chip(value)
                        }
                    }
                }
            }
        }
    }
}

extension Section {
    private func chip(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Etykieta, która po kliknięciu szuka samej siebie.
///
/// Bez fokusu klawiatury z tego samego powodu co przycisk tekstu w panelu:
/// fokus na plakietce odbierałby cyfry ocenianiu, a plakietki zmieniają się
/// z każdym zdjęciem.
private struct SearchLabel<Label: View>: View {
    let value: String
    let onSearch: (String) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { onSearch(value) } label: { label() }
            .buttonStyle(.plain)
            .focusable(false)
            .pointerStyle(.link)
            .help("Show photos with \(value)")
    }
}

/// Układ zawijający — `HStack` nie zawija, a `LazyVGrid` wymusza równe
/// kolumny, przez co „Sky" zajmowałoby tyle co „Aerial Photography".
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for row in arrange(subviews: subviews, width: bounds.width) {
            subviews[row.index].place(
                at: CGPoint(x: bounds.minX + row.x, y: bounds.minY + row.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(
        subviews: Subviews, width: CGFloat
    ) -> [(index: Int, x: CGFloat, y: CGFloat, height: CGFloat)] {
        var placed: [(Int, CGFloat, CGFloat, CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            placed.append((index, x, y, size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return placed
    }
}
#endif
