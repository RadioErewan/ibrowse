import SwiftUI

/// Ocenianie gestem: w lewo gorsze, w prawo lepsze.
///
/// To nie jest sito „zostaw / do kosza", tylko **przesuwanie wagi**. Nigdy nie
/// odpowiadasz na pytanie „ile to jest warte", tylko „w górę czy w dół względem
/// tego, co przed chwilą widziałem" — pytanie nieporównywalnie tańsze poznawczo.
/// Przez wiele podejść archiwum układa się samo, a ocena zawsze jest względem
/// dzisiejszego gustu, nie tego sprzed sześciu lat.
///
/// Gest pisze do tej samej `weight`, co klawisze na Macu. Jeden skład, dwa
/// sposoby wprowadzania.
///
/// **W pionie przechodzi się dalej bez oceny.** Pominięcie musi być równie
/// tanie jak ocena, inaczej pierwsze wątpliwe zdjęcie zatrzymuje całą pracę
/// albo — gorzej — dostaje ocenę wymuszoną brakiem wyjścia.
struct SwipeCard<Content: View>: View {
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
                y: isVertical ? offset.height : offset.height / 4
            )
            // Lekki obrót — ruch czytelny kątem oka, bez patrzenia na etykietę.
            .rotationEffect(.degrees(isVertical ? 0 : offset.width / 28), anchor: .bottom)
            .overlay { verdict }
            .animation(.interactiveSpring(duration: 0.25), value: offset)
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { value in
                        let vertical = abs(value.translation.height) > abs(value.translation.width)
                        let travelled = vertical ? value.translation.height : value.translation.width

                        if abs(travelled) >= commitDistance {
                            if vertical {
                                // W górę dalej, w dół wstecz — tak jak przewija
                                // się listę: treść jedzie w stronę ruchu palca.
                                onStep(travelled < 0 ? 1 : -1)
                            } else {
                                onNudge(travelled > 0 ? 1 : -1)
                            }
                        }
                        offset = .zero
                    }
            )
    }

    /// Znak i siła zamiaru, zanim puścisz palec — żeby dało się wycofać ruch
    /// bez konsekwencji.
    @ViewBuilder
    private var verdict: some View {
        if progress > 0.15 {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(tint)
                // Pominięcie jest bledsze od oceny celowo: to ruch bez skutku
                // i nie ma udawać decyzji.
                .opacity(progress * (isVertical ? 0.7 : 1))
                .scaleEffect(0.7 + 0.3 * progress)
                .allowsHitTesting(false)
        }
    }

    private var symbol: String {
        if isVertical {
            return offset.height < 0 ? "chevron.up.circle.fill" : "chevron.down.circle.fill"
        }
        return offset.width > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    private var tint: Color {
        if isVertical { return .white }
        return offset.width > 0 ? .green : .orange
    }
}
