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

    /// Dwuklik na kafelku wchodzi w ocenianie od tego zdjęcia. To jedyne
    /// zadanie siatki: nawigacja po archiwum i wejście w wybranym miejscu.
    /// Sama przeglądarka miniatur nie służy do oceniania — kusi do
    /// przewijania, a nie do decydowania.
    var onOpen: (PHAsset) -> Void = { _ in }
    @Query private var reviews: [Review]

    #if os(macOS)
    @State private var thumbSize: Double = 140
    #else
    /// Na telefonie kafelek dobiera się sam — cztery kolumny mieszczą się
    /// wygodnie w kciuku i nie wymagają regulacji.
    private let thumbSize: Double = 92
    #endif

    private var ratings: [String: Int] {
        Dictionary(reviews.map { ($0.assetID, $0.stars) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pasek pomiarowy i suwak rozmiaru to narzędzia pracy przy
            // dużym ekranie. Na telefonie zabierają jedną trzecią widoku
            // i nie dają nic w zamian — zdjęcia mają zajmować ekran.
            #if os(macOS)
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                Slider(value: $thumbSize, in: 80...280) { Text("rozmiar") }
                    .frame(width: 180)
                Spacer()
                PerfOverlay(monitor: monitor, total: library.visibleAssets.count)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()
            #endif

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 3)],
                    spacing: 3
                ) {
                    ForEach(library.visibleAssets, id: \.localIdentifier) { asset in
                        Thumbnail(
                            asset: asset,
                            library: library,
                            monitor: monitor,
                            side: thumbSize,
                            rating: ratings[asset.localIdentifier] ?? 0
                        )
                        .onTapGesture(count: 2) { onOpen(asset) }
                    }
                }
                .padding(3)
            }
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

    private var screenScale: Double {
        #if os(macOS)
        return Double(NSScreen.main?.backingScaleFactor ?? 2)
        #else
        return Double(UIScreen.main.scale)
        #endif
    }

    private func cancel() {
        guard let request else { return }
        library.cancel(request)
        self.request = nil
        monitor.didFinishLoad()
    }
}
