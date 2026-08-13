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
/// dwa ruchy zamiast jednego i cała szybkość by wyparowała. Zostaje więc
/// jeden gest na ocenę, a odruchowy ruch w bok jest nieszkodliwy.
///
/// Gest pisze do tej samej `weight`, co klawisze na Macu. Jeden skład, dwa
/// sposoby wprowadzania.
struct SwipeCard<Content: View>: View {
    /// +1 lepsze, −1 gorsze. Wywołujący sam decyduje, czy przechodzi dalej.
    let onNudge: (Double) -> Void
    /// +1 następne, −1 poprzednie. Bez zapisywania czegokolwiek.
    var onStep: (Int) -> Void = { _ in }
    @ViewBuilder var content: Content

    @State private var offset: CGSize = .zero

    /// Dystans, po którym gest się liczy. Na tyle duży, żeby przypadkowe
    /// muśnięcie przy przewijaniu nie zmieniło oceny.
    private let commitDistance: CGFloat = 90

    /// Oś rozstrzygamy przewagą jednego kierunku nad drugim, a nie samym
    /// przekroczeniem progu. Palec nigdy nie idzie idealnie prosto i bez tego
    /// ukośny ruch potrafiłby jednocześnie ocenić i przeskoczyć.
    private var isVertical: Bool { abs(offset.height) > abs(offset.width) }

    private var progress: Double {
        min(abs(isVertical ? offset.height : offset.width) / commitDistance, 1)
    }

    var body: some View {
        content
            .offset(
                x: isVertical ? 0 : offset.width,
                y: isVertical ? offset.height : 0
            )
            .overlay { verdict }
            .animation(.interactiveSpring(duration: 0.25), value: offset)
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { value in
                        let vertical = abs(value.translation.height) > abs(value.translation.width)
                        let travelled = vertical ? value.translation.height : value.translation.width

                        if abs(travelled) >= commitDistance {
                            // W obu osiach ruch „do przodu" idzie w stronę
                            // ujemną: w lewo następne zdjęcie, w górę wyższa
                            // ocena. Treść jedzie za palcem.
                            if vertical {
                                onNudge(travelled < 0 ? 1 : -1)
                            } else {
                                onStep(travelled < 0 ? 1 : -1)
                            }
                        }
                        offset = .zero
                    }
            )
    }

    /// Znak i siła zamiaru, zanim puścisz palec — żeby dało się wycofać ruch
    /// bez konsekwencji. Strzałka wskazuje teraz tam, gdzie idzie palec;
    /// w poprzedniej wersji ruch w prawo pokazywał strzałkę w górę.
    @ViewBuilder
    private var verdict: some View {
        if progress > 0.15 {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(tint)
                // Przewijanie jest bledsze od oceny celowo: to ruch bez
                // skutku i nie ma udawać decyzji.
                .opacity(progress * (isVertical ? 1 : 0.7))
                .scaleEffect(0.7 + 0.3 * progress)
                .allowsHitTesting(false)
        }
    }

    private var symbol: String {
        if isVertical {
            return offset.height < 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        }
        return offset.width < 0 ? "chevron.right.circle.fill" : "chevron.left.circle.fill"
    }

    private var tint: Color {
        guard isVertical else { return .white }
        return offset.height < 0 ? .green : .orange
    }
}
