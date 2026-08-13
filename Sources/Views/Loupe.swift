import Photos
import SwiftUI

/// Podgląd 1:1 — jedyne miejsce, w którym widzisz prawdziwe piksele.
///
/// Bez tego nie da się ocenić ostrości, a ostrość jest pierwszym pytaniem przy
/// odsiewie. Reszta aplikacji pracuje na podglądach do 2048 px, bo to szybkie
/// i tanie — ale **lupka nad takim podglądem kłamałaby**: pokazywałaby
/// wygładzone powiększenie i odrzucałbyś ostre zdjęcia jako miękkie.
///
/// Stąd dwie zasady. Po pierwsze, oryginał dociągamy dopiero na żądanie, nigdy
/// z góry. Po drugie, gdy oryginału nie ma, mówimy to wprost zamiast pokazywać
/// powiększony podgląd — narzędzie do oceniania nie ma prawa zmyślać
/// materiału, na podstawie którego podejmujesz decyzje.
struct Loupe: View {
    let asset: PHAsset
    let library: PhotoLibrary
    @Binding var isPresented: Bool

    /// Miejsce, na którym ma się otworzyć kadr — na Macu tam, gdzie stał
    /// kursor. Przy zdjęciu 8000 px środek jest prawie zawsze złą odpowiedzią:
    /// ostrość sprawdza się w konkretnym punkcie, na który się właśnie patrzy.
    var focus: UnitPoint = .center

    @State private var image: PlatformImage?
    @State private var request: PHImageRequestID?
    @State private var finished = false

    /// Na Macu wolno dociągnąć z iCloud: miejsca jest więcej, a systemowa
    /// polityka „Optymalizuj pamięć" i tak eksmituje najstarsze oryginały.
    /// Na telefonie **nigdy** — tam pobrany oryginał zostaje na stałe,
    /// a PhotoKit nie daje sposobu, żeby go usunąć.
    private var allowNetwork: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                // Zwykły `ScrollView` zamiast własnego przesuwania kadru:
                // daje gładkie panoramowanie gładzikiem i palcem, pilnuje
                // krańców i nie wymaga ani linijki kodu na obsługę gestu.
                ScrollView([.horizontal, .vertical]) {
                    Image(platformImage: image)
                        .resizable()
                        .frame(width: side(image).width, height: side(image).height)
                }
                .defaultScrollAnchor(focus)
            } else if finished {
                unavailable
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(allowNetwork ? "dociągam oryginał…" : "szukam oryginału na urządzeniu…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            badge
        }
        .task(id: asset.localIdentifier) { load() }
        .onDisappear { cancel() }
        #if os(macOS)
        .onExitCommand { isPresented = false }
        #endif
    }

    /// Jeden piksel zdjęcia na jeden piksel ekranu. W punktach to znaczy
    /// podzielić przez skalę ekranu — na Retinie inaczej dostalibyśmy
    /// powiększenie 2:1 i znów oglądalibyśmy interpolację.
    private func side(_ image: PlatformImage) -> CGSize {
        CGSize(
            width: Double(asset.pixelWidth) / screenScale,
            height: Double(asset.pixelHeight) / screenScale
        )
    }

    private var screenScale: Double {
        #if os(macOS)
        return Double(NSScreen.main?.backingScaleFactor ?? 2)
        #else
        return Double(UIScreen.main.scale)
        #endif
    }

    private var badge: some View {
        VStack {
            HStack {
                if image != nil {
                    Text("1:1 · \(asset.pixelWidth)×\(asset.pixelHeight)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            Spacer()
        }
    }

    /// Na telefonie to najczęstszy przypadek, nie wyjątek — większość
    /// oryginałów leży wyłącznie w iCloud.
    private var unavailable: some View {
        ContentUnavailableView {
            Label("Brak oryginału na urządzeniu", systemImage: "icloud.slash")
        } description: {
            Text("Podgląd, który widzisz, jest zmniejszony — nie da się z niego ocenić ostrości. Oryginału nie pobieram, bo zostałby tu na stałe.")
        }
    }

    private func load() {
        cancel()
        image = nil
        finished = false
        request = library.original(for: asset, allowNetwork: allowNetwork) { loaded in
            image = loaded
            finished = true
        }
    }

    private func cancel() {
        if let request { library.cancel(request) }
        request = nil
    }
}
