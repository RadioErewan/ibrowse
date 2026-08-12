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
struct SwipeCard<Content: View>: View {
    let onNudge: (Double) -> Void
    @ViewBuilder var content: Content

    @State private var offset: CGSize = .zero
    @GestureState private var dragging = false

    /// Dystans, po którym gest się liczy. Na tyle duży, żeby przypadkowe
    /// muśnięcie przy przewijaniu nie zmieniło oceny.
    private let commitDistance: CGFloat = 90

    private var progress: Double {
        min(abs(offset.width) / commitDistance, 1)
    }

    private var direction: Double {
        offset.width > 0 ? 1 : -1
    }

    var body: some View {
        content
            .offset(x: offset.width, y: offset.height / 4)
            // Lekki obrót — ruch czytelny kątem oka, bez patrzenia na etykietę.
            .rotationEffect(.degrees(offset.width / 28), anchor: .bottom)
            .overlay { verdict }
            .animation(.interactiveSpring(duration: 0.25), value: offset)
            .gesture(
                DragGesture()
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { offset = $0.translation }
                    .onEnded { value in
                        if abs(value.translation.width) >= commitDistance {
                            onNudge(value.translation.width > 0 ? 1 : -1)
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
            let better = direction > 0
            Image(systemName: better ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(better ? .green : .orange)
                .opacity(progress)
                .scaleEffect(0.7 + 0.3 * progress)
                .allowsHitTesting(false)
        }
    }
}
