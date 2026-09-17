#if os(macOS)
import Photos
import SwiftData
import SwiftUI

/// Swobodne porównanie dwóch dowolnych kadrów — poza turniejem.
///
/// Parowanie odpowiada na pytanie „które z tych dwóch jest lepsze" i samo
/// dobiera pary wewnątrz wykrytej serii. Tu wybierasz ręcznie i **nic się nie
/// ocenia samo**: to jest narzędzie do patrzenia, nie do rozstrzygania.
///
/// A i B to **dwa wskaźniki na tej samej kolejce**, nie druga lista zdjęć.
/// Ta zasada jest w projekcie od czasu, gdy zestawienie cech miało własny
/// zbiór i kliknięcie w nie wyprowadzało donikąd — patrz `Filters`.
struct CompareView: View {
    let queue: [PHAsset]
    @ObservedObject var library: PhotoLibrary
    @Binding var pair: (a: String, b: String)?
    var orderName: String = ""
    var onClose: () -> Void = {}

    @Query(filter: #Predicate<Review> { $0.isRated || $0.markedForDeletion })
    private var reviews: [Review]

    /// Wspólne powiększenie to **ten sam współczynnik i to samo przesunięcie**.
    /// Bez tego porównanie ostrości nie działa: patrzy się wtedy na dwa różne
    /// wycinki dwóch różnych kadrów i wygrywa ten, który akurat trafił w oko.
    @AppStorage("compare.sharedZoom") private var sharedZoom = true

    /// Powiększenie jednego panelu. Przy wspólnym obie strony czytają i piszą
    /// ten sam zestaw, przy osobnym każda swój — dlatego to jest struktura,
    /// a nie trzy luźne pola.
    struct Zoom {
        var scale: Double = 1
        var offset: CGSize = .zero
        var settled: CGSize = .zero
    }

    @State private var left = Zoom()
    @State private var right = Zoom()

    /// Przy wspólnym powiększeniu prawa strona czyta stan lewej. To jest cały
    /// mechanizm: jedno źródło zamiast dwóch zsynchronizowanych.
    private var rightZoom: Binding<Zoom> {
        sharedZoom ? $left : $right
    }

    private var a: PHAsset? { pair.flatMap { library.asset(id: $0.a) } }
    private var b: PHAsset? { pair.flatMap { library.asset(id: $0.b) } }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()

            HStack(spacing: 2) {
                pane(a, mark: "A", tint: .yellow, zoom: $left)
                pane(b, mark: "B", tint: .accentColor, zoom: rightZoom)
            }
            .frame(maxHeight: .infinity)

            Divider()
            strip
        }
        .background(Color.black)
        .background { keys }
        // Nowy kadr zawsze wchodzi dopasowany. Bez tego zdjęcie o innych
        // proporcjach wjeżdża przesunięte poza panel i wygląda na puste.
        .task(id: "\(pair?.a ?? "")|\(pair?.b ?? "")") {
            left = Zoom()
            right = Zoom()
        }
    }

    /// Klawiatura przez **skróty przycisków**, nie przez `onKeyPress`.
    ///
    /// `onKeyPress` wymaga, żeby widok miał focus, a w tym oknie zabierał go
    /// przełącznik wspólnego powiększenia i pasek miniatur — strzałki i `esc`
    /// milczały, i nie dało się stąd wyjść inaczej niż myszą. Skrót przycisku
    /// idzie łańcuchem odpowiedzi i działa niezależnie od tego, co ma focus.
    ///
    /// Przyciski są niewidoczne, ale **nie** `hidden` — ukryte tracą skróty.
    @ViewBuilder
    private var keys: some View {
        VStack {
            Button("") { step(-1, side: .b) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1, side: .b) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { step(-1, side: .a) }.keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { step(1, side: .a) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { swap() }.keyboardShortcut("s", modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .frame(width: 0, height: 0)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Text("porównanie")
                .font(.headline)
            Text("ten sam zbiór · \(queue.count)\(orderName.isEmpty ? "" : " · \(orderName)")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Text("← → zmienia B · ⇧← ⇧→ zmienia A · S zamienia strony")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Toggle("wspólne powiększenie", isOn: $sharedZoom)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)

            Button("esc — powrót do siatki", action: onClose)
                .buttonStyle(.plain)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func pane(
        _ asset: PHAsset?, mark: String, tint: Color, zoom: Binding<Zoom>
    ) -> some View {
        ZStack {
            Color.black
            if let asset {
                AssetImage(
                    asset: asset, library: library,
                    targetSize: CGSize(width: 2048, height: 2048),
                    chrome: false
                )
                .scaleEffect(zoom.wrappedValue.scale)
                .offset(zoom.wrappedValue.offset)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) { label(mark, tint: tint) }
        .overlay(alignment: .bottom) { if let asset { footer(asset) } }
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    zoom.wrappedValue.offset = CGSize(
                        width: zoom.wrappedValue.settled.width + value.translation.width,
                        height: zoom.wrappedValue.settled.height + value.translation.height
                    )
                }
                .onEnded { _ in zoom.wrappedValue.settled = zoom.wrappedValue.offset }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { zoom.wrappedValue.scale = max(1, $0.magnification) }
        )
        .overlay(alignment: .topTrailing) {
            if zoom.wrappedValue.scale > 1.01 {
                Text(String(format: "%.0f%%", zoom.wrappedValue.scale * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
    }

    private func label(_ mark: String, tint: Color) -> some View {
        Text(mark)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint == .yellow ? .black : .white)
            .frame(width: 22, height: 22)
            .background(tint, in: RoundedRectangle(cornerRadius: 4))
            .padding(8)
    }

    /// Nad zdjęciem tekst **zawsze** na podkładce — bez niej ginie na
    /// pierwszym jasnym kadrze, a tu jasne kadry są regułą.
    private func footer(_ asset: PHAsset) -> some View {
        let review = reviews.first { $0.assetID == asset.localIdentifier }
        return HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= (review?.stars ?? 0) ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(value <= (review?.stars ?? 0)
                                     ? Color.yellow : Color.white.opacity(0.35))
            }
            if let review, review.isRated {
                Text(String(format: "%.2f", review.weight))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
            }
            if let date = asset.creationDate {
                Text(date, format: .dateTime.day().month().year())
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    /// Pasek pokazuje **tę samą kolejkę**, z zaznaczonymi A i B. Widać z niego,
    /// skąd biorą się obie strony i co przyjdzie następne.
    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 3) {
                    ForEach(queue, id: \.localIdentifier) { asset in
                        let id = asset.localIdentifier
                        let isA = id == pair?.a
                        let isB = id == pair?.b
                        AssetThumbnail(asset: asset, library: library)
                            .frame(width: 84, height: 84)
                            .clipped()
                            .opacity(isA || isB ? 1 : 0.55)
                            .overlay {
                                if isA {
                                    Rectangle().strokeBorder(.yellow, lineWidth: 3)
                                } else if isB {
                                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                                }
                            }
                            .onTapGesture { pair = (a: pair?.a ?? id, b: id) }
                            .id(id)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 96)
            .background(.bar)
            .task(id: pair?.b) {
                guard let b = pair?.b else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(b, anchor: .center) }
            }
        }
    }

    // MARK: - Nawigacja

    private enum Side { case a, b }

    private func step(_ delta: Int, side: Side) {
        guard let pair else { return }
        let id = side == .a ? pair.a : pair.b
        guard let index = queue.firstIndex(where: { $0.localIdentifier == id }) else { return }
        let next = min(max(index + delta, 0), queue.count - 1)
        let moved = queue[next].localIdentifier
        self.pair = side == .a ? (a: moved, b: pair.b) : (a: pair.a, b: moved)
    }

    private func swap() {
        guard let pair else { return }
        self.pair = (a: pair.b, b: pair.a)
    }
}
#endif
