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

    /// `nil` znaczy „jeszcze nie ustawione" — dopiero wtedy wolno skoczyć
    /// na punkt kursora. Bez tego rozróżnienia każde przerysowanie widoku
    /// odrzucałoby przesunięcie i wracało do miejsca kliknięcia.
    @State private var settled: CGSize?
    @State private var pan: CGSize = .zero

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
                // Przesunięcie liczone wprost, zamiast `ScrollView`
                // z `defaultScrollAnchor`. Tamto ustawia pozycję przy
                // **pierwszym układzie**, a ten powstaje, zanim zdjęcie
                // dojdzie z dysku — kotwica trafiała w pustkę i kadr
                // otwierał się gdzie indziej niż kliknięcie. Tu punkt
                // wyliczamy dopiero wtedy, gdy znamy oba rozmiary.
                GeometryReader { geometry in
                    Image(platformImage: image)
                        .resizable()
                        .frame(width: side.width, height: side.height)
                        .offset(current(in: geometry.size))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let from = settled ?? centred(on: focus, in: geometry.size)
                                    pan = CGSize(
                                        width: from.width + value.translation.width,
                                        height: from.height + value.translation.height
                                    )
                                    settled = clamped(pan, in: geometry.size)
                                }
                        )
                }
                .clipped()
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
    private var side: CGSize {
        CGSize(
            width: Double(asset.pixelWidth) / screenScale,
            height: Double(asset.pixelHeight) / screenScale
        )
    }

    private func current(in window: CGSize) -> CGSize {
        clamped(settled ?? centred(on: focus, in: window), in: window)
    }

    /// Przesunięcie, przy którym wskazany punkt zdjęcia ląduje na środku okna.
    private func centred(on point: UnitPoint, in window: CGSize) -> CGSize {
        CGSize(
            width: window.width / 2 - point.x * side.width,
            height: window.height / 2 - point.y * side.height
        )
    }

    /// Nie pozwala wyjechać poza zdjęcie. Gdy wymiar mieści się w oknie
    /// w całości, jest wyśrodkowany — szarpanie krótszą osią nic nie wnosi.
    private func clamped(_ offset: CGSize, in window: CGSize) -> CGSize {
        func fit(_ value: CGFloat, _ content: CGFloat, _ available: CGFloat) -> CGFloat {
            guard content > available else { return (available - content) / 2 }
            return min(max(value, available - content), 0)
        }
        return CGSize(
            width: fit(offset.width, side.width, window.width),
            height: fit(offset.height, side.height, window.height)
        )
    }

    /// Skala **tego** ekranu, nie „głównego".
    ///
    /// Wcześniej było tu `NSScreen.main`, czyli ekran z aktywnym oknem według
    /// systemu — a to nie musi być ekran, na którym stoi nasze okno. Przy
    /// dwóch monitorach o różnej gęstości 1:1 wychodziło dwa razy za małe
    /// i przesunięcie kadru było liczone w złej jednostce. `displayScale`
    /// przychodzi ze środowiska widoku, więc zmienia się razem z przeniesieniem
    /// okna na drugi monitor.
    @Environment(\.displayScale) private var displayScale
    private var screenScale: Double { Double(displayScale) }

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
