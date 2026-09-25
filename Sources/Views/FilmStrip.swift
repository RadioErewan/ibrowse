import Photos
import SwiftUI

/// Pasek miniatur pod zdjęciem — **widzialna kolejka**.
///
/// Powstał z konkretnej awarii: dopóki kolejka była niewidoczna, nie dało się
/// zauważyć, że zestawienie cech i ocenianie chodzą po dwóch różnych zbiorach.
/// Dowiadywało się o tym dopiero po geście, gdy przyjeżdżało zdjęcie nie z tej
/// parafii. Pasek pokazuje ten sam zbiór, w tej samej kolejności, więc
/// rozjazd byłby widoczny od pierwszej chwili, a nie do wyśledzenia.
///
/// Poza tym robi to, po co paski miniatur istnieją: pozwala skoczyć dalej niż
/// o jedno zdjęcie, nie wychodząc do siatki. Powrót o osiem kadrów przestaje
/// kosztować utratę kontekstu.
///
/// Nie jest mapą całości i nie udaje nią być. Przy 26 tysiącach zdjęć żaden
/// pasek nie zmieści archiwum — to okno wokół bieżącego miejsca, przewijalne
/// palcem, ale wracające do bieżącego zdjęcia przy każdym kroku.
struct FilmStrip: View {
    let assets: [PHAsset]
    let index: Int
    @ObservedObject var library: PhotoLibrary
    /// Zwykła referencja, **nie obserwacja**: pomiar publikuje zmianę co pół
    /// sekundy i przy każdym wczytanym obrazku. Obserwowany stąd przebudowywał
    /// cały widok razem z oknem za każdym razem — przy szybkim ocenianiu okno
    /// układało się od nowa kilka razy na krok. Obserwuje go tylko `PerfOverlay`.
    let monitor: PerfMonitor

    /// Podpis pod miarą, która jest w grze. W pasku znaczy więcej niż
    /// w siatce: widzisz nie tylko **co** będzie następne, ale i **jak bardzo**.
    var badge: (String) -> String? = { _ in nil }

    var marked: Set<String> = []

    var onPick: (Int) -> Void

    #if os(macOS)
    private let side: Double = 62
    #else
    private let side: Double = 52
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { position, asset in
                        Thumbnail(
                            asset: asset,
                            library: library,
                            monitor: monitor,
                            side: side,
                            rating: 0,
                            badge: badge(asset.localIdentifier),
                            isFocus: position == index,
                            isMarkedForDeletion: marked.contains(asset.localIdentifier)
                        )
                        // Pojedyncze kliknięcie także na Macu: to element
                        // sterowania, nie zdjęcie do zaznaczania.
                        .onTapGesture { onPick(position) }
                        .id(asset.localIdentifier)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: side + 4)
            // Bieżące zdjęcie zostaje na środku, a nie na krawędzi — inaczej
            // pasek pokazuje wyłącznie przyszłość i nie da się z niego cofnąć.
            .task(id: index) { await centre(on: index, using: proxy) }
        }
        .background(.bar)
    }

    private func centre(on position: Int, using proxy: ScrollViewProxy) async {
        guard assets.indices.contains(position) else { return }
        // `LazyHStack` w chwili pojawienia się nie zna jeszcze swojej
        // szerokości — `scrollTo` puszczone wcześniej trafia w próżnię.
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(assets[position].localIdentifier, anchor: .center)
        }
    }
}
