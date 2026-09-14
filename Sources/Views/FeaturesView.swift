import Photos
import SwiftData
import SwiftUI

/// Przeglądy poprzeczne przez archiwum **cudzą miarą** — tą, którą policzył
/// system, nie tą, którą postawiłeś sam.
///
/// Zestawienie, nie ocena. Żadna z tych liczb nie dotyka wagi zdjęcia; mają
/// tylko pokazać archiwum od strony, z której normalnie się go nie widzi:
/// najbardziej poruszone, najgorzej naświetlone, z zamkniętymi oczami.
///
/// Cechy czyta z bazy systemu **wyłącznie macOS** (patrz `FeatureImport`), ale
/// widok działa na obu platformach, bo wynik jedzie do telefonu w ocenie.
/// Dzięki temu przegląd w samolocie nie wymaga ani sieci, ani Maca.
struct FeaturesView: View {
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var monitor: PerfMonitor

    /// Te same warunki, co w pozostałych trybach — **i to nie jest ozdoba**.
    ///
    /// Ocenianie szuka wskazanego zdjęcia w zbiorze zawężonym filtrami. Gdy
    /// zestawienie pokazywało zdjęcia spoza tego zbioru, kliknięcie w takie
    /// zdjęcie nie trafiało w nic: wskaźnik zostawał na miejscu i otwierało się
    /// zupełnie inne zdjęcie. Przy filtrze „od 2018" dotyczyło to połowy
    /// archiwum.
    @ObservedObject var filters: Filters

    var onOpen: (PHAsset) -> Void = { _ in }

    /// Zdjęcie, na którym stoi praca — wspólne dla wszystkich trybów.
    /// Zestawienie przewija się do niego przy wejściu, więc powrót z oceniania
    /// wraca tam, gdzie się kliknęło, a nie na początek listy.
    var focusID: String?

    @Query private var reviews: [Review]
    @Environment(\.modelContext) private var context

    #if os(macOS)
    @StateObject private var importer = FeatureImport()
    @State private var thumbSize: Double = 140
    #else
    private let thumbSize: Double = 92
    #endif

    /// Miara i próg **przeżywają zmianę trybu**.
    ///
    /// Przełączenie na ocenianie usuwa ten widok z hierarchii, a razem z nim
    /// znika każde `@State`. Po dwukliku i powrocie zestawienie wracało więc
    /// do ostrości i progu 0,70, gubiąc to, co się właśnie przeglądało.
    /// `@AppStorage` przeżywa nie tylko przełączenie trybu, ale i zamknięcie
    /// aplikacji — tak samo jak stan panelu metadanych w `CullView`.
    @AppStorage("features.lens") private var lensRaw = Lens.sharpness.rawValue
    @AppStorage("features.threshold") private var threshold = 0.7

    private var lens: Lens {
        get { Lens(rawValue: lensRaw) ?? .sharpness }
        nonmutating set { lensRaw = newValue.rawValue }
    }

    private var lensBinding: Binding<Lens> {
        Binding(get: { lens }, set: { lens = $0 })
    }

    /// Miara, według której patrzymy na archiwum. Każda odpowiada na inne
    /// pytanie, więc każda ma własny próg i własny podpis na kafelku.
    enum Lens: String, CaseIterable, Identifiable {
        case sharpness = "ostrość"
        case exposure = "ekspozycja"
        case eyes = "zamknięte oczy"
        case screenshots = "zrzuty ekranu"
        var id: String { rawValue }

        /// Czy miara jest ciągła — tylko wtedy próg ma sens.
        var isContinuous: Bool { self == .sharpness || self == .exposure }

        var hint: String {
            switch self {
            case .sharpness: "niżej = bardziej rozmyte"
            case .exposure: "niżej = gorzej naświetlone"
            case .eyes: "najpierw najwięcej zamkniętych oczu"
            case .screenshots: "rozpoznane przez system"
            }
        }
    }

    /// Wynik przeglądu liczony **raz na zmianę warunków**, nie przy każdym
    /// odrysowaniu.
    ///
    /// Po wczytaniu cech ocen jest 25 tysięcy, a zdjęć 26 tysięcy. Liczenie
    /// tego w ciele widoku kosztowało tyle, że interfejs stawał: przeciągnięcie
    /// suwaka progu przelicza się wtedy przy każdej klatce, a słownik ocen
    /// budował się od nowa dla każdego kafelka z osobna.
    @State private var shown: [Entry] = []
    @State private var withFeatures = 0

    struct Entry: Identifiable {
        let asset: PHAsset
        let badge: String
        let stars: Int
        var id: String { asset.localIdentifier }
    }

    /// Wszystko, co wymusza przeliczenie. Zmiana czegokolwiek z tego —
    /// i tylko wtedy — puszcza je na nowo.
    private var trigger: String {
        "\(lens.rawValue)|\(threshold)|\(reviews.count)|\(library.assets.count)"
        + "|\(filters.base.count)|\(filters.standing.rawValue)"
        + "|\(filters.minStars)|\(filters.maxStars)"
    }

    private func recompute() {
        // Jeden słownik na całe przeliczenie. Poprzednia wersja sięgała po
        // właściwość obliczaną wewnątrz pętli, więc powstawał osobno dla
        // każdego zdjęcia — 25 tysięcy słowników po 25 tysięcy pozycji.
        let index = Dictionary(
            reviews.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a }
        )
        withFeatures = reviews.reduce(into: 0) { total, review in
            if review.hasFeatures { total += 1 }
        }

        // Ten sam zbiór, po którym chodzi ocenianie — inaczej kliknięcie
        // wyprowadza poza niego i otwiera nie to zdjęcie.
        let candidates = filters.apply(index)

        switch lens {
        case .sharpness, .exposure:
            let value: (Review) -> Double = lens == .sharpness
                ? { $0.sharpness } : { $0.exposure }
            shown = candidates
                .compactMap { asset -> (PHAsset, Double, Int)? in
                    guard let review = index[asset.localIdentifier] else { return nil }
                    let score = value(review)
                    // Zero to brak pomiaru, nie zdjęcie beznadziejne — bez tego
                    // nieprzeanalizowane zajęłyby cały początek zestawienia.
                    guard score > 0, score < threshold else { return nil }
                    return (asset, score, review.stars)
                }
                .sorted { $0.1 < $1.1 }
                .map { Entry(asset: $0.0, badge: String(format: "%.2f", $0.1), stars: $0.2) }

        case .eyes:
            shown = candidates
                .compactMap { asset -> (PHAsset, Int, Int, Int)? in
                    guard let review = index[asset.localIdentifier],
                          review.eyesClosed > 0 else { return nil }
                    return (asset, review.eyesClosed,
                            max(review.faces, review.eyesClosed), review.stars)
                }
                .sorted { $0.1 > $1.1 }
                .map { Entry(asset: $0.0, badge: "\($0.1) z \($0.2)", stars: $0.3) }

        case .screenshots:
            shown = candidates.compactMap { asset in
                guard let review = index[asset.localIdentifier],
                      review.isScreenshot else { return nil }
                return Entry(asset: asset, badge: "zrzut", stars: review.stars)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls(count: shown.count)
            Divider()

            if withFeatures == 0 {
                empty
            } else {
                grid(shown)
            }
        }
        // Zwłoka po ustaniu ruchu suwakiem — ten sam zabieg, co przy czułości
        // grupowania serii. Bez niej każda klatka przeciągania sortuje 26
        // tysięcy zdjęć od nowa.
        .task(id: trigger) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            recompute()
        }
    }

    @ViewBuilder
    private var empty: some View {
        #if os(macOS)
        ContentUnavailableView(
            "Brak policzonych cech",
            systemImage: "camera.metering.spot",
            description: Text(
                importer.summary
                ?? "Cechy leżą w bazach biblioteki Zdjęć. Wczytaj je przyciskiem powyżej — "
                 + "wymaga to Pełnego dostępu do dysku w Ustawieniach systemowych."
            )
        )
        #else
        ContentUnavailableView(
            "Brak policzonych cech",
            systemImage: "camera.metering.spot",
            description: Text(
                "Cechy liczy system na Macu i przyjeżdżają tu synchronizacją. "
                + "Wczytaj je na Macu, zsynchronizuj oba urządzenia i wróć tutaj."
            )
        )
        #endif
    }

    @ViewBuilder
    private func controls(count: Int) -> some View {
        #if os(macOS)
        HStack(spacing: 12) {
            Picker("", selection: lensBinding) {
                ForEach(Lens.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)

            if lens.isContinuous {
                Slider(value: $threshold, in: 0.1...1.0) { Text("próg") }
                    .frame(width: 140)
                Text(String(format: "poniżej %.2f", threshold))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 14)
            Text("\(count) z \(withFeatures)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Text(lens.hint).font(.caption).foregroundStyle(.tertiary)
            importControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        #else
        VStack(spacing: 8) {
            Picker("", selection: lensBinding) {
                ForEach(Lens.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                if lens.isContinuous {
                    Slider(value: $threshold, in: 0.1...1.0) { Text("próg") }
                    Text(String(format: "%.2f", threshold))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(lens.hint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #endif
    }

    #if os(macOS)
    /// Wczytanie cech jest jawną operacją na całym archiwum — tak samo jak
    /// liczenie odcisków i dokładnie z tego samego powodu.
    @ViewBuilder
    private var importControl: some View {
        if importer.isWorking {
            ProgressView().controlSize(.small)
        } else {
            Button {
                Task { await importer.run(context: context, library: library) }
            } label: {
                Label("wczytaj cechy", systemImage: "square.and.arrow.down")
            }
            .help("Czyta ostrość, ekspozycję i twarze z baz biblioteki Zdjęć")
        }
    }
    #endif

    @ViewBuilder
    private func grid(_ shown: [Entry]) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 3)],
                spacing: 3
            ) {
                ForEach(shown) { entry in
                    Thumbnail(
                        asset: entry.asset,
                        library: library,
                        monitor: monitor,
                        side: thumbSize,
                        rating: entry.stars,
                        badge: entry.badge,
                        isFocus: entry.asset.localIdentifier == focusID
                    )
                    #if os(iOS)
                    .onTapGesture { onOpen(entry.asset) }
                    #else
                    .onTapGesture(count: 2) { onOpen(entry.asset) }
                    #endif
                }
            }
            .padding(3)
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(
                    "Nic nie pasuje",
                    systemImage: "checkmark.circle",
                    description: Text(lens.isContinuous
                        ? "Żadne zdjęcie nie ma wyniku niższego niż \(String(format: "%.2f", threshold))."
                        : "Żadne zdjęcie nie pasuje do tej miary.")
                )
            }
        }
        // Przewijamy dopiero, gdy zestawienie jest już policzone — `scrollTo`
        // puszczone do pustej siatki trafia w próżnię. Stąd zależność także
        // od liczby pozycji, nie tylko od samego zdjęcia.
        .task(id: "\(focusID ?? "")|\(shown.count)") {
            guard let focusID, shown.contains(where: { $0.id == focusID }) else { return }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(focusID, anchor: .center)
            }
        }
        }
    }
}
