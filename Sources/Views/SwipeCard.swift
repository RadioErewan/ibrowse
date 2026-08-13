import Photos
import SwiftUI

/// Gesty w trybie oceniania: **w bok przewijasz, w pionie oceniasz**.
///
/// Pierwsza wersja miała to odwrotnie, z apek randkowych: w lewo gorsze,
/// w prawo lepsze. Sprawdziło się źle i to nie kwestia gustu — Radek chciał
/// przewinąć zdjęcie i wystawił mu ocenę. Błąd idzie tu w kosztowną stronę,
/// bo zostawia w skali wpis, którego nikt nie zamierzał. Pomyłka odwrotna
/// (chcę ocenić, przewinąłem) nie kosztuje nic.
///
/// Trzy powody, dla których ten podział jest właściwy:
///
/// - **Częstotliwość.** Przez zdjęcia przechodzi się stale, ocenia rzadziej.
///   Najczęstsza czynność zasługuje na najbardziej odruchowy gest.
/// - **Konwencja.** Poziomy swipe to przewijanie w każdej galerii. Apki
///   randkowe są wyjątkiem, w którym ruch w bok *też* znaczy „następna" —
///   werdykt jest doklejony do przejścia, nie zastępuje go.
/// - **Semantyka.** Pion pasuje do wartości: w górę więcej, w dół mniej.
///   Poziom to oś kolejności.
///
/// **Ocena przechodzi dalej za jednym zamachem** — bez tego odsiew kosztowałby
/// dwa ruchy zamiast jednego i cała szybkość by wyparowała.
///
/// Ciągnięcie w bok **wsuwa sąsiada zza krawędzi**, więc widać, co jest dalej,
/// zanim się tam pójdzie. To odpowiedź na pytanie „czy następne jest z tej
/// samej beczki" bez opuszczania zdjęcia — i przy okazji zwalnia stopkę
/// ze strzałek, bo ruch tłumaczy się sam.
struct SwipeCard<Content: View>: View {
    /// +1 lepsze, −1 gorsze. Wywołujący sam decyduje, czy przechodzi dalej.
    let onNudge: (Double) -> Void
    /// +1 następne, −1 poprzednie. Bez zapisywania czegokolwiek.
    var onStep: (Int) -> Void = { _ in }

    let library: PhotoLibrary
    var previous: PHAsset?
    var next: PHAsset?

    @ViewBuilder var content: Content

    @State private var offset: CGSize = .zero

    /// Dystans, po którym gest się liczy. Na tyle duży, żeby przypadkowe
    /// muśnięcie przy przewijaniu nie zmieniło oceny.
    private let commitDistance: CGFloat = 90
    private let gap: CGFloat = 8

    /// Oś rozstrzygamy przewagą jednego kierunku nad drugim, a nie samym
    /// przekroczeniem progu. Palec nigdy nie idzie idealnie prosto i bez tego
    /// ukośny ruch potrafiłby jednocześnie ocenić i przeskoczyć.
    private var isVertical: Bool { abs(offset.height) > abs(offset.width) }

    private var progress: Double {
        min(abs(isVertical ? offset.height : offset.width) / commitDistance, 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let step = geometry.size.width + gap

            HStack(spacing: gap) {
                neighbour(previous, width: geometry.size.width)
                content.frame(width: geometry.size.width)
                neighbour(next, width: geometry.size.width)
            }
            .offset(
                x: -step + (isVertical ? 0 : offset.width),
                y: isVertical ? offset.height : 0
            )
            .animation(.interactiveSpring(duration: 0.25), value: offset)
            .overlay { verdict }
            .contentShape(Rectangle())
            .gesture(drag(width: geometry.size.width))
        }
    }

    /// Sąsiad jest miniaturą, nie pełnym zdjęciem: ma odpowiedzieć na pytanie
    /// „co dalej", a nie nadawać się do oceny ostrości. Pusty kadr na końcach
    /// zbioru mówi wprost, że dalej nic nie ma.
    @ViewBuilder
    private func neighbour(_ asset: PHAsset?, width: CGFloat) -> some View {
        if let asset {
            AssetThumbnail(asset: asset, library: library)
                .frame(width: width)
                .opacity(0.85)
        } else {
            Color.black.frame(width: width)
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { offset = $0.translation }
            .onEnded { value in
                let vertical = abs(value.translation.height) > abs(value.translation.width)
                let travelled = vertical ? value.translation.height : value.translation.width

                guard abs(travelled) >= commitDistance else {
                    offset = .zero          // odbicie: gest wycofany
                    return
                }

                // Po zatwierdzeniu treść zmienia się pod spodem, więc powrót
                // do zera musi być bez animacji. Animowany dawałby wrażenie,
                // że **nowe** zdjęcie wjeżdża z powrotem spod krawędzi.
                var instant = Transaction()
                instant.disablesAnimations = true

                // W obu osiach ruch „do przodu" idzie w stronę ujemną:
                // w lewo następne zdjęcie, w górę wyższa ocena.
                if vertical {
                    onNudge(travelled < 0 ? 1 : -1)
                } else {
                    onStep(travelled < 0 ? 1 : -1)
                }
                withTransaction(instant) { offset = .zero }
            }
    }

    /// Znak i siła zamiaru, zanim puścisz palec — żeby dało się wycofać ruch
    /// bez konsekwencji. Przy ruchu w bok nie ma żadnego znaku: tam mówi sam
    /// sąsiad wjeżdżający zza krawędzi.
    @ViewBuilder
    private var verdict: some View {
        if isVertical && progress > 0.15 {
            Image(systemName: offset.height < 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(offset.height < 0 ? .green : .orange)
                .opacity(progress)
                .scaleEffect(0.7 + 0.3 * progress)
                .allowsHitTesting(false)
        }
    }
}
