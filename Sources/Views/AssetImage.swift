import Photos
import SwiftUI

/// Wyświetla jeden asset, sam zarządzając cyklem życia żądania do PhotoKit.
/// Anuluje poprzednie żądanie przy zmianie zdjęcia — bez tego szybkie
/// przewijanie klawiszem zostawia za sobą stos wiszących pobrań.
struct AssetImage: View {
    let asset: PHAsset
    let library: PhotoLibrary
    var targetSize: CGSize = CGSize(width: 2048, height: 2048)

    /// Własne plakietki widoku — licznik pikseli i „dociągam z iCloud".
    ///
    /// Wyłączane tam, gdzie zdjęcie jest jednym z dwóch obok siebie i ma
    /// własne podpisy: dwie warstwy kapsuł w tych samych rogach nakładają się
    /// na siebie, a plakietka dociągania miga przy każdej kolejnej wersji
    /// zdjęcia przysłanej przez PhotoKit. Przy jednym zdjęciu to sygnał,
    /// przy dwóch — migotanie.
    var chrome: Bool = true

    @State private var image: PlatformImage?
    @State private var isDegraded = true
    @State private var request: PHImageRequestID?
    @State private var localRequest: PHImageRequestID?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }

            // Sygnał, że widać jeszcze miniaturę, a pełna wersja się dociąga
            // z iCloud. Bez tego łatwo ocenić ostrość na podglądzie 360px.
            // Faktyczna rozdzielczość tego, co widzisz — żeby dało się
            // odróżnić lokalny podgląd od dociągniętego oryginału.
            if let image, chrome {
                VStack {
                    HStack {
                        Text(Self.pixels(image))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                            .padding(10)
                        Spacer()
                    }
                    Spacer()
                }
            }

            if isDegraded && image != nil && chrome {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label("dociągam z iCloud", systemImage: "icloud.and.arrow.down")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                            .padding(10)
                    }
                }
            }
        }
        .task(id: asset.localIdentifier) { load() }
        .onDisappear { cancel() }
    }

    /// Dwustopniowo: najpierw najlepszy wariant z dysku, potem — jeśli
    /// oryginał jest tylko w iCloud — podmiana na pełną rozdzielczość.
    /// Jedno żądanie dawało albo natychmiastową miniaturę 64×37, albo czarny
    /// ekran na czas pobierania. Dwa dają jedno i drugie we właściwej kolejności.
    private func load() {
        cancel()
        image = nil
        isDegraded = true

        localRequest = library.localImage(for: asset, targetSize: targetSize) { local in
            // Nie nadpisujemy wersji pełnej, gdyby zdążyła przyjść pierwsza.
            if let local, isDegraded { image = local }
        }

        request = library.image(for: asset, targetSize: targetSize) { loaded, degraded in
            if let loaded { image = loaded }
            isDegraded = degraded
        }
    }

    private func cancel() {
        if let request { library.cancel(request) }
        if let localRequest { library.cancel(localRequest) }
        request = nil
        localRequest = nil
    }
}

extension AssetImage {
    static func pixels(_ image: PlatformImage) -> String {
        #if os(macOS)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "?"
        }
        return "\(cg.width)×\(cg.height)"
        #else
        guard let cg = image.cgImage else { return "?" }
        return "\(cg.width)×\(cg.height)"
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
