import Photos
import SwiftUI

/// Lekki podgląd zdjęcia — bez dociągania z iCloud, bez pomiarów.
///
/// Osobno od `AssetImage`, bo tamten służy do oglądania i dokłada starań
/// (dwa stopnie ładowania, pełna rozdzielczość, znacznik pobierania). Tutaj
/// chodzi wyłącznie o rozpoznanie „czy to dalej ta sama beczka", więc bierzemy
/// to, co leży w pamięci podręcznej, i nie generujemy ruchu do sieci.
struct AssetThumbnail: View {
    let asset: PHAsset
    let library: PhotoLibrary
    var side: Double = 300

    @State private var image: PlatformImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: asset.localIdentifier) { load() }
        .onDisappear { cancel() }
    }

    private func load() {
        cancel()
        image = nil
        request = library.thumbnail(for: asset, side: side * screenScale) { loaded, degraded in
            if let loaded { image = loaded }
            guard !degraded else { return }
            request = nil
        }
    }

    /// Skala **tego** ekranu, nie „głównego" — patrz komentarz w `Loupe`.
    /// Przy dwóch monitorach o różnej gęstości `NSScreen.main` potrafi wskazać
    /// nie ten, na którym stoi okno, i miniatury robiły się rozmyte.
    @Environment(\.displayScale) private var displayScale
    private var screenScale: Double { Double(displayScale) }

    private func cancel() {
        if let request { library.cancel(request) }
        request = nil
    }
}
