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

    @FocusState private var focused: Bool

    /// Powiększenie jednego panelu. Przy wspólnym obie strony czytają i piszą
    /// ten sam zestaw, przy osobnym każda swój — dlatego to jest struktura,
    /// a nie trzy luźne pola.
    struct Zoom {
        var scale: Double = 1
        var offset: CGSize = .zero
        var settled: CGSize = .zero

        /// Krok z klawiatury, wokół środka panelu: przesunięcie rośnie razem
        /// ze skalą, więc oglądany wycinek zostaje na miejscu. Od 1× (całe
        /// zdjęcie) do 8×; na 1× przesunięcie wraca do zera.
        mutating func zoom(by factor: Double) {
            let next = min(max(scale * factor, 1), 8)
            let ratio = next / scale
            scale = next
            if next <= 1 {
                offset = .zero
            } else {
                offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
            }
            settled = offset
        }
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
        // Strzałki obsługujemy tu, jednym miejscem, a nie skrótami na
        // przyciskach. Skróty `←` (strona B) i `⇧←` (strona A) na dwóch
        // przyciskach macOS mylił — strzałka niesie własne modyfikatory
        // zdarzenia — i para rozjeżdżała się: `←` cofało A, `→` przesuwało B.
        // Przełącznik powiększenia i pasek nie przyjmują fokusu, więc
        // klawiatura zostaje tutaj.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { DispatchQueue.main.async { focused = true } }
        // Powiększenie z klawiatury — szczypanie na gładziku bywa trudne do
        // trafienia, a myszą nie było go wcale. Przy wspólnym powiększeniu
        // prawa strona i tak czyta lewą, przy osobnym klawisz działa na obie.
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-0")) { press in
            switch press.characters {
            case "+", "=":
                left.zoom(by: 1.5)
                if !sharedZoom { right.zoom(by: 1.5) }
            case "-":
                left.zoom(by: 1 / 1.5)
                if !sharedZoom { right.zoom(by: 1 / 1.5) }
            default:
                left = Zoom()
                right = Zoom()
            }
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let delta = press.key == .leftArrow ? -1 : 1
            step(delta, side: press.modifiers.contains(.shift) ? .a : .b)
            return .handled
        }
        // Nowy kadr zawsze wchodzi dopasowany. Bez tego zdjęcie o innych
        // proporcjach wjeżdża przesunięte poza panel i wygląda na puste.
        .task(id: "\(pair?.a ?? "")|\(pair?.b ?? "")") {
            left = Zoom()
            right = Zoom()
        }
    }

    /// Nawigacja widocznymi przyciskami — do klikania i żeby było widać, że
    /// strony da się przełączać. Klawisze obsługuje `onKeyPress` całego widoku.
    ///
    /// Historia: skróty na ukrytych przyciskach nie trafiały w łańcuch
    /// odpowiedzi (system piszczał); `onKeyPress` tracił fokus na rzecz
    /// przełącznika powiększenia i paska; skróty `←`/`⇧←` na widocznych
    /// przyciskach macOS mylił między stronami. Teraz przełącznik i przyciski
    /// nie przyjmują fokusu, więc `onKeyPress` go nie traci.
    @ViewBuilder
    private func stepper(_ side: Side, label: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(side == .a ? Color.yellow : Color.accentColor)
            Button {
                step(-1, side: side)
            } label: {
                Image(systemName: "chevron.left")
            }
            Button {
                step(1, side: side)
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .focusable(false)
        .help(side == .a ? "⇧← / ⇧→" : "← / →")
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Text("comparison")
                .font(.headline)
            Text("same set · \(queue.count)\(orderName.isEmpty ? "" : " · \(orderName)")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            stepper(.a, label: "A")
            stepper(.b, label: "B")

            Button {
                swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("s", modifiers: [])
            .help("S — swap sides")

            Text("+/− zoom · 0 fit")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)

            Toggle("shared zoom", isOn: $sharedZoom)
                .toggleStyle(.switch)
                .controlSize(.small)
                .focusable(false)
                .help("+ / − zoom · 0 fit · drag to move")
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
                            library.setRating(updated.stars, for: asset.localIdentifier)
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
