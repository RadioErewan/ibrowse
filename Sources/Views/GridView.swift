import Photos
import SwiftData
import SwiftUI

/// Siatka nad całą biblioteką — test wytrzymałości SwiftUI na skali archiwum.
///
/// Celowo bez stronicowania i bez sztuczek: wszystkie assety wpadają do
/// `LazyVGrid`, tak jak zrobiłby to ktoś piszący to naiwnie. Jeśli to wyrobi
/// na 25 tysiącach, nie ma powodu schodzić do NSCollectionView.
struct GridView: View {
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var monitor: PerfMonitor
    @ObservedObject var filters: Filters

    /// Stuknięcie w kafelek wchodzi w ocenianie od tego zdjęcia (na Macu
    /// dwuklik). To jedyne zadanie siatki: nawigacja po archiwum i wejście
    /// w wybranym miejscu. Sama przeglądarka miniatur nie służy do oceniania
    /// — kusi do przewijania, a nie do decydowania.
    var onOpen: (PHAsset) -> Void = { _ in }

    /// Zdjęcie, na którym stoi praca w pozostałych trybach. Siatka przewija
    /// się do niego przy wejściu i oznacza je ramką.
    ///
    /// Bez tego powrót z oceniania lądował na początku archiwum — po godzinie
    /// pracy w 2019 roku dostawało się widok pierwszego zdjęcia z 2007
    /// i trzeba było odnajdywać się ręcznie.
    var focusID: String?

    @Query private var reviews: [Review]

    #if os(macOS)
    @State private var thumbSize: Double = 140
    #else
    /// Na telefonie kafelek dobiera się sam — cztery kolumny mieszczą się
    /// wygodnie w kciuku i nie wymagają regulacji.
    private let thumbSize: Double = 92
    #endif

    private var byID: [String: Review] {
        Dictionary(reviews.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let reviewIndex = byID
        let shown = filters.apply(reviewIndex)

        return VStack(spacing: 0) {
            // Pasek pomiarowy i suwak rozmiaru to narzędzia pracy przy
            // dużym ekranie. Na telefonie zabierają jedną trzecią widoku
            // i nie dają nic w zamian — zdjęcia mają zajmować ekran.
            #if os(macOS)
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                Slider(value: $thumbSize, in: 80...280) { Text("rozmiar") }
                    .frame(width: 180)
                Spacer()
                PerfOverlay(monitor: monitor, total: shown.count)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()
            #endif

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 3)],
                        spacing: 3
                    ) {
                        ForEach(shown, id: \.localIdentifier) { asset in
                            Thumbnail(
                                asset: asset,
                                library: library,
                                monitor: monitor,
                                side: thumbSize,
                                rating: reviewIndex[asset.localIdentifier]?.stars ?? 0,
                                isFocus: asset.localIdentifier == focusID
                            )
                            // Na telefonie otwiera pojedyncze stuknięcie, bo
                            // tak działa każda galeria i nie ma tu czego
                            // zaznaczać. Przewijaniu to nie przeszkadza: gest
                            // dotknięcia nie odpala się, gdy palec wędruje.
                            // Na Macu zostaje dwuklik — pojedyncze kliknięcie
                            // należy się zaznaczaniu.
                            #if os(iOS)
                            .onTapGesture { onOpen(asset) }
                            #else
                            .onTapGesture(count: 2) { onOpen(asset) }
                            #endif
                        }
                    }
                    .padding(3)
                }
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView(
                            "Nic nie pasuje",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("Żadne zdjęcie nie spełnia warunków filtru.")
                        )
                    }
                }
                .task(id: focusID) { await reveal(focusID, using: proxy) }
            }
        }
    }

    /// Przewija do zdjęcia, na którym stoi praca.
    ///
    /// Krótka zwłoka jest konieczna: `LazyVGrid` w chwili pojawienia się widoku
    /// nie zna jeszcze swojej wysokości, a `scrollTo` przed ustaleniem układu
    /// trafia w próżnię. Wyśrodkowanie zamiast dosunięcia do góry daje kontekst
    /// — widać, co było przed i po.
    private func reveal(_ id: String?, using proxy: ScrollViewProxy) async {
        guard let id else { return }
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// Jedna komórka siatki. Zgłasza start i koniec ładowania do monitora, więc
/// widać, ile żądań wisi jednocześnie przy szybkim scrollu.
private struct Thumbnail: View {
    let asset: PHAsset
    let library: PhotoLibrary
    let monitor: PerfMonitor
    let side: Double
    let rating: Int

    /// Zdjęcie, od którego przyszliśmy z innego trybu. Samo przewinięcie nie
    /// wystarcza — wśród setek podobnych kafelków środek ekranu nic nie znaczy.
    let isFocus: Bool

    @State private var image: PlatformImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            }
            if rating > 0 {
                VStack {
                    Spacer()
                    HStack(spacing: 1) {
                        ForEach(0..<rating, id: \.self) { _ in
                            Image(systemName: "star.fill").font(.system(size: 7))
                        }
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(3)
                }
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay {
            if isFocus {
                Rectangle().strokeBorder(.yellow, lineWidth: 3)
            }
        }
        .contentShape(Rectangle())
        .onAppear { load() }
        .onDisappear { cancel() }
    }

    private func load() {
        guard image == nil, request == nil else { return }
        monitor.didStartLoad()

        // Skala ekranu, a nie sztywne ×2 — inaczej na Retinie prosimy
        // o za mało pikseli i kafelek jest rozmyty mimo ostrego źródła.
        let px = side * screenScale

        request = library.thumbnail(for: asset, side: px) { loaded, degraded in
            if let loaded { image = loaded }
            // Handler przy `opportunistic` woła się dwa razy; żądanie jest
            // zamknięte dopiero po wersji pełnej.
            guard !degraded else { return }
            request = nil
            monitor.didFinishLoad()
        }
    }

    /// Skala **tego** ekranu, nie „głównego" — patrz komentarz w `Loupe`.
    /// Przy dwóch monitorach o różnej gęstości `NSScreen.main` potrafi wskazać
    /// nie ten, na którym stoi okno, i miniatury robiły się rozmyte.
    @Environment(\.displayScale) private var displayScale
    private var screenScale: Double { Double(displayScale) }

    private func cancel() {
        guard let request else { return }
        library.cancel(request)
        self.request = nil
        monitor.didFinishLoad()
    }
}
