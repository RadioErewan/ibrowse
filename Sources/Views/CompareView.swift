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
    @Environment(\.modelContext) private var context

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
        // Nowy kadr zawsze wchodzi dopasowany. Bez tego zdjęcie o innych
        // proporcjach wjeżdża przesunięte poza panel i wygląda na puste.
        .task(id: "\(pair?.a ?? "")|\(pair?.b ?? "")") {
            left = Zoom()
            right = Zoom()
        }
    }

    /// Nawigacja **prawdziwymi przyciskami**, nie ukrytymi.
    ///
    /// Pierwsze podejście trzymało skróty na przyciskach zerowej wielkości
    /// z zerową przezroczystością, schowanych w tle. macOS takich nie wpuszcza
    /// do łańcucha odpowiedzi — klawisz nie trafiał w nic, więc system piszczał.
    /// Drugie podejście, `onKeyPress`, wymagało focusu, a ten zabierał
    /// przełącznik powiększenia i pasek miniatur.
    ///
    /// Widoczne przyciski rozwiązują oba problemy naraz i przy okazji pokazują,
    /// że te klawisze w ogóle istnieją.
    @ViewBuilder
    private func stepper(_ side: Side, label: String, modifiers: EventModifiers) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(side == .a ? Color.yellow : Color.accentColor)
            Button {
                step(-1, side: side)
            } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: modifiers)
            Button {
                step(1, side: side)
            } label: {
                Image(systemName: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: modifiers)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Text("comparison")
                .font(.headline)
            Text("same set · \(queue.count)\(orderName.isEmpty ? "" : " · \(orderName)")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            stepper(.a, label: "A", modifiers: .shift)
            stepper(.b, label: "B", modifiers: [])

            Button {
                swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("s", modifiers: [])
            .help("S — swap sides")

            Toggle("shared zoom", isOn: $sharedZoom)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)

            Button("esc — back to the grid", action: onClose)
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
            // Gwiazdki klikalne także tutaj. Porównanie samo niczego nie
            // ocenia — to nie turniej — ale skoro właśnie patrzysz na dwa kadry
            // obok siebie, to jest moment, w którym wniosek zapada. Odsyłanie
            // po ocenę do siatki kazałoby wyjść z jedynego widoku, w którym
            // widać, dlaczego ocena ma być taka, a nie inna.
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= (review?.stars ?? 0) ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(value <= (review?.stars ?? 0)
                                     ? Color.yellow : Color.white.opacity(0.35))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let (updated, changed) = Review.upsertRating(
                            assetID: asset.localIdentifier, in: context
                        ) { $0.set(Double(value)) }
                        if changed {
                            Task { await library.setRating(updated.stars, for: asset.localIdentifier) }
                        }
                    }
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
