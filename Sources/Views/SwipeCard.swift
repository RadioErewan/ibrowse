import Photos
import SwiftUI

/// Gesty w trybie oceniania: **w bok przewijasz, w pionie oceniasz**.
///
/// Pierwsza wersja miała to odwrotnie, z apek randkowych: w lewo gorsze,
/// w prawo lepsze. Sprawdziło się źle i to nie kwestia gustu: chcąc przewinąć
/// zdjęcie, wystawiało mu się ocenę. Błąd idzie tu w kosztowną stronę,
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

    /// Bieżąca waga zdjęcia i krok oceny — po to, żeby w trakcie gestu
    /// pokazać **konkretny wynik**, a nie samą strzałkę. `nil` znaczy, że
    /// zdjęcie jest jeszcze nieocenione.
    var weight: Double?
    var stepValue: Double = 0.25

    @ViewBuilder var content: Content

    @State private var offset: CGSize = .zero
    /// Blokada na czas dojeżdżania kadru. Bez niej drugi gest w trakcie
    /// animacji przeskakiwałby dwa zdjęcia i gubił jedno po drodze.
    @State private var isCommitting = false

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

    /// Pion **stawia opór**: zdjęcie daje się pociągnąć, ale nie odjeżdża.
    ///
    /// Bez tego oba gesty wyglądały tak samo — kadr wędrował za palcem
    /// i ruch w górę czytało się jak przewijanie, którym nie jest. Poziom
    /// zostaje jeden do jednego, bo tam kadr faktycznie ma odjechać.
    private var verticalTravel: CGFloat {
        guard !isCommitting else { return offset.height }
        let sign: CGFloat = offset.height < 0 ? -1 : 1
        return sign * min(abs(offset.height) * 0.45, 120)
    }

    /// Czy w tę stronę jest jeszcze co pokazywać. Ruch w prawo sięga po
    /// poprzednie zdjęcie, ruch w lewo po następne.
    private func atEdge(_ travel: CGFloat) -> Bool {
        (travel > 0 && previous == nil) || (travel < 0 && next == nil)
    }

    /// Na krańcach zbioru kadr **idzie na gumce**.
    ///
    /// Wcześniej jechał jeden do jednego w czarną pustkę i wracał — wyglądało
    /// to jak zacięcie, a nie jak koniec. Opór jest tu jedynym uczciwym
    /// komunikatem: dalej nic nie ma i nie chodzi o siłę gestu.
    private var horizontalTravel: CGFloat {
        guard !isCommitting else { return offset.width }
        guard atEdge(offset.width) else { return offset.width }
        let sign: CGFloat = offset.width < 0 ? -1 : 1
        return sign * min(abs(offset.width) * 0.28, 56)
    }

    private var target: Double {
        min(max((weight ?? 2.5) + (offset.height < 0 ? stepValue : -stepValue), 0), 5)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            // Kolejność jest tu istotna. Taśma z sąsiadami jest **trzy ekrany
            // szeroka** i dwa razy już narzuciła swój rozmiar temu, co miało
            // się trzymać ekranu — najpierw nakładce, potem obejmującemu ją
            // stosowi. Za każdym razem wskaźnik oceny lądował poza widokiem.
            //
            // Teraz rozmiar dyktuje tło wielkości ekranu, a taśma jest jego
            // nakładką: wyśrodkowana, czyli bieżące zdjęcie samo staje na
            // środku, bez żadnego przesunięcia w spoczynku.
            Color.black
                .overlay {
                    HStack(spacing: gap) {
                        neighbour(previous, width: width)
                        content.frame(width: width)
                        neighbour(next, width: width)
                    }
                    .offset(
                        x: isVertical ? 0 : horizontalTravel,
                        y: isVertical ? verticalTravel : 0
                    )
                }
                .clipped()
                .overlay { verdict }
                .contentShape(Rectangle())
                .gesture(drag(step: width + gap, height: geometry.size.height))
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

    /// Ruch pod palcem idzie bez animacji — ma nadążać jeden do jednego.
    /// Animowane są tylko dwa zakończenia: odbicie przy geście wycofanym
    /// i dojazd przy zatwierdzonym.
    private func drag(step: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isCommitting else { return }
                offset = value.translation
            }
            .onEnded { value in
                guard !isCommitting else { return }

                let vertical = abs(value.translation.height) > abs(value.translation.width)
                let travelled = vertical ? value.translation.height : value.translation.width

                // Na krańcu nie ma czego zatwierdzać — samo odbicie.
                guard abs(travelled) >= commitDistance,
                      vertical || !atEdge(travelled) else {
                    withAnimation(.spring(duration: 0.25)) { offset = .zero }
                    return
                }
                commit(vertical: vertical, forward: travelled < 0, step: step, height: height)
            }
    }

    /// Kadr **dojeżdża do końca**, dopiero potem podmieniamy zdjęcie.
    ///
    /// Wcześniej podmiana następowała od razu, a przesunięcie wracało do zera
    /// bez animacji — czysto, ale nie dało się poznać, czy gest w ogóle się
    /// policzył. Teraz ruch kończy się tam, gdzie prowadził palec: sąsiad
    /// dojeżdża na środek i dopiero wtedy staje się bieżącym zdjęciem.
    private func commit(vertical: Bool, forward: Bool, step: CGFloat, height: CGFloat) {
        isCommitting = true
        let duration: Double = vertical ? 0.18 : 0.22

        withAnimation(.easeOut(duration: duration)) {
            if vertical {
                // Ocenione zdjęcie odlatuje w stronę werdyktu.
                offset = CGSize(width: 0, height: forward ? -height : height)
            } else {
                offset = CGSize(width: forward ? -step : step, height: 0)
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))

            // W obu osiach ruch „do przodu" idzie w stronę ujemną: w lewo
            // następne zdjęcie, w górę wyższa ocena.
            if vertical {
                onNudge(forward ? 1 : -1)
            } else {
                onStep(forward ? 1 : -1)
            }

            // Treść jest już podmieniona, więc powrót do zera musi być bez
            // animacji — inaczej **nowe** zdjęcie wjeżdżałoby z powrotem
            // spod krawędzi, czyli w odwrotną stronę niż szedł palec.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { offset = .zero }

            isCommitting = false
        }
    }

    /// Zamiar pokazany **konkretną liczbą**, zanim puścisz palec.
    ///
    /// Sama strzałka mówiła tylko „w górę", co równie dobrze mogło znaczyć
    /// przewijanie. Plus i minus mówią „ocena", a docelowa waga mówi ile —
    /// przy kroku 0,25 to jedyny sposób, żeby wiedzieć, gdzie się właśnie
    /// wylądowało bez patrzenia w stopkę po fakcie.
    ///
    /// Przy ruchu w bok nie ma żadnego znaku: tam mówi sam sąsiad wjeżdżający
    /// zza krawędzi.
    @ViewBuilder
    private var verdict: some View {
        if isVertical && progress > 0.2 {
            let better = offset.height < 0
            let tint: Color = better ? .green : .orange
            let armed = progress >= 1

            VStack(spacing: 8) {
                Image(systemName: better ? "plus.circle.fill" : "minus.circle.fill")
                    .font(.system(size: 52, weight: .semibold))

                Text(weight == nil
                     ? "first rating · \(Self.number(target))"
                     : "\(Self.number(weight ?? 0)) → \(Self.number(target))")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            // Obwódka zapala się dopiero po przekroczeniu progu — to znaczy
            // „puść, a zapiszę". Poniżej progu gest jeszcze nic nie robi.
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(tint, lineWidth: armed ? 3 : 0)
            }
            .opacity(0.55 + 0.45 * progress)
            .scaleEffect(0.9 + 0.1 * progress)
            .allowsHitTesting(false)
        }
    }

    /// Przecinek, nie kropka — to jest liczba czytana po polsku.
    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }
}
