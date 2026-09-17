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
    @State private var scale: Double = 1
    @State private var offset: CGSize = .zero
    @State private var settled: CGSize = .zero
    @FocusState private var focused: Bool

    private var a: PHAsset? { pair.flatMap { library.asset(id: $0.a) } }
    private var b: PHAsset? { pair.flatMap { library.asset(id: $0.b) } }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()

            HStack(spacing: 2) {
                pane(a, mark: "A", tint: .yellow)
                pane(b, mark: "B", tint: .accentColor)
            }
            .frame(maxHeight: .infinity)

            Divider()
            strip
        }
        .background(Color.black)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)
        .onKeyPress(.leftArrow) { step(-1, side: .b); return .handled }
        .onKeyPress(.rightArrow) { step(1, side: .b); return .handled }
        .onKeyPress(.tab) { swap(); return .handled }
        .onKeyPress { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            switch press.key {
            case .leftArrow: step(-1, side: .a); return .handled
            case .rightArrow: step(1, side: .a); return .handled
            default: return .ignored
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Text("porównanie")
                .font(.headline)
            Text("ten sam zbiór · \(queue.count)\(orderName.isEmpty ? "" : " · \(orderName)")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Toggle("wspólne powiększenie", isOn: $sharedZoom)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)

            Button("esc — powrót do siatki", action: onClose)
                .buttonStyle(.plain)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func pane(_ asset: PHAsset?, mark: String, tint: Color) -> some View {
        ZStack {
            Color.black
            if let asset {
                AssetImage(
                    asset: asset, library: library,
                    targetSize: CGSize(width: 2048, height: 2048)
                )
                .scaleEffect(scale)
                .offset(offset)
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
                    offset = CGSize(width: settled.width + value.translation.width,
                                    height: settled.height + value.translation.height)
                }
                .onEnded { _ in settled = offset }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { scale = max(1, $0.magnification) }
        )
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.66), in: Capsule())
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
