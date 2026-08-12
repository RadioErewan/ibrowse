import Photos
import SwiftData
import SwiftUI

/// Główny widok pracy: jedno zdjęcie na pełnym ekranie, ocena z klawiatury.
///
/// Świadomie nie ma tu siatki jako trybu domyślnego — przy przeglądaniu
/// archiwum siatka kusi do przewijania, a nie do decydowania.
struct CullView: View {
    @ObservedObject var library: PhotoLibrary

    /// Wspólny wskaźnik „gdzie jestem w archiwum", jeden na całą aplikację.
    ///
    /// Działa w obie strony: dwuklik w siatce ustawia go i wchodzi tutaj,
    /// a każdy krok strzałką zapisuje go z powrotem, więc powrót do siatki
    /// trafia w to samo miejsce zamiast na początek biblioteki.
    @Binding var focusID: String?
    @Environment(\.modelContext) private var context
    @Query private var reviews: [Review]

    @FocusState private var focused: Bool
    @State private var index = 0
    @State private var filter: Filter = .all
    @State private var showingDeletions = false

    #if os(macOS)
    @StateObject private var metadata = MetadataIndex()
    /// Domyślnie otwarty — po to powstał. Zapamiętany, bo przy szybkim
    /// odsiewie panel bywa zbędny i nie chcę go zamykać przy każdym wejściu.
    @AppStorage("cull.showingMetadata") private var showingMetadata = true
    #endif

    enum Filter: String, CaseIterable, Identifiable {
        case all = "wszystkie"
        case unrated = "nieocenione"
        case rated = "ocenione"
        case marked = "do usunięcia"
        var id: String { rawValue }
    }

    // MARK: - Zbiór roboczy

    private var byID: [String: Review] {
        Dictionary(reviews.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var workingSet: [PHAsset] {
        let index = byID
        switch filter {
        case .all:
            return library.visibleAssets
        case .unrated:
            return library.visibleAssets.filter { index[$0.localIdentifier]?.isRated != true }
        case .rated:
            return library.visibleAssets.filter { index[$0.localIdentifier]?.isRated == true }
        case .marked:
            return library.visibleAssets.filter { index[$0.localIdentifier]?.markedForDeletion == true }
        }
    }

    private var current: PHAsset? {
        let set = workingSet
        guard set.indices.contains(index) else { return nil }
        return set[index]
    }

    private var currentReview: Review? {
        current.flatMap { byID[$0.localIdentifier] }
    }

    private var markedCount: Int {
        reviews.filter(\.markedForDeletion).count
    }

    // MARK: - Widok

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                stage
                #if os(macOS)
                if showingMetadata {
                    Divider()
                    MetadataPanel(asset: current, index: metadata)
                        .frame(width: 260)
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .focusable()
        .focusEffectDisabled()
        // `.focusable()` pozwala przyjąć focus, ale go nie nadaje. Przy
        // przełączeniu trybu klawiatura trafiała w poprzedni widok i strzałki
        // milczały, dopóki nie kliknęło się w zdjęcie.
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { step(1); return .handled }
        .onKeyPress { press in handle(press.characters) }
        .onChange(of: filter) { _, _ in index = 0 }
        // Skacze tylko wtedy, gdy wskaźnik przyszedł z zewnątrz. Bez tego
        // warunku widok reagowałby na własne zapisy i pętla by się zapętliła.
        .task(id: focusID) {
            focused = true
            guard let focusID, focusID != current?.localIdentifier,
                  let position = workingSet.firstIndex(where: { $0.localIdentifier == focusID })
            else { return }
            index = position
        }
        .sheet(isPresented: $showingDeletions) {
            DeletionReview(library: library, reviews: reviews.filter(\.markedForDeletion))
        }
        .task(id: index) {
            prefetchNeighbours()
            focusID = current?.localIdentifier
        }
    }

    private var stage: some View {
        ZStack {
            Color.black
            if let current {
                #if os(iOS)
                // Na telefonie gest zastępuje klawiaturę: w lewo gorsze,
                // w prawo lepsze. Przesuwa tę samą wagę, o ten sam krok.
                SwipeCard { direction in
                    nudge(direction)
                    step(1)
                } content: {
                    AssetImage(asset: current, library: library)
                }
                #else
                AssetImage(asset: current, library: library)
                #endif
            } else {
                ContentUnavailableView(
                    "Pusto",
                    systemImage: "photo",
                    description: Text("Żadne zdjęcie nie pasuje do filtru: \(filter.rawValue)")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            Spacer()

            #if os(macOS)
            Toggle(isOn: $showingMetadata) {
                Label("metadane", systemImage: "info.circle")
            }
            .toggleStyle(.button)
            .help("Panel metadanych (klawisz I)")
            #endif

            if markedCount > 0 {
                Button {
                    showingDeletions = true
                } label: {
                    Label("\(markedCount) do usunięcia", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            stars

            if currentReview?.markedForDeletion == true {
                Label("do usunięcia", systemImage: "trash.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }

            Spacer()

            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("\(workingSet.isEmpty ? 0 : index + 1) / \(workingSet.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var stars: some View {
        HStack(spacing: 3) {
            if let review = currentReview, review.isRated {
                Text(String(format: "%.2f", review.weight))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= (currentReview?.stars ?? 0) ? "star.fill" : "star")
                    .foregroundStyle(value <= (currentReview?.stars ?? 0)
                                     ? Color.yellow : Color.secondary.opacity(0.35))
                    .onTapGesture { rate(Double(value)) }
            }
        }
        .font(.system(size: 15))
    }

    private var hint: String {
        #if os(iOS)
        "przesuń w lewo gorsze · w prawo lepsze"
        #else
        "1–5 ocena · −/+ przesuń · X do usunięcia · I metadane · ←/→ nawigacja"
        #endif
    }

    // MARK: - Akcje

    private func handle(_ characters: String) -> KeyPress.Result {
        guard let key = characters.first else { return .ignored }
        switch key {
        case "0"..."5":
            rate(Double(String(key)) ?? 0)
            return .handled
        case "-", "_":
            nudge(-1)
            return .handled
        case "=", "+":
            nudge(+1)
            return .handled
        case "x", "X":
            toggleDeletion()
            return .handled
        #if os(macOS)
        case "i", "I":
            showingMetadata.toggle()
            return .handled
        #endif
        default:
            return .ignored
        }
    }

    private func rate(_ value: Double) {
        guard let asset = current else { return }
        Review.upsert(assetID: asset.localIdentifier, in: context) { $0.set(value) }
        step(1)
    }

    /// Przesunięcie wagi bez opuszczania zdjęcia — odpowiednik swipe'a
    /// z telefonu, żeby oba urządzenia pisały do tej samej liczby.
    private func nudge(_ direction: Double) {
        guard let asset = current else { return }
        Review.upsert(assetID: asset.localIdentifier, in: context) { $0.nudge(direction) }
    }

    private func toggleDeletion() {
        guard let asset = current else { return }
        Review.upsert(assetID: asset.localIdentifier, in: context) {
            $0.markedForDeletion.toggle()
        }
        step(1)
    }

    private func step(_ delta: Int) {
        let set = workingSet
        guard !set.isEmpty else { return }
        index = min(max(index + delta, 0), set.count - 1)
    }

    /// Trzy zdjęcia w przód i jedno w tył — tyle wystarczy, żeby szybkie
    /// klikanie klawiszem nie czekało na dysk ani na iCloud.
    private func prefetchNeighbours() {
        let set = workingSet
        let window = ((index - 1)...(index + 3)).compactMap { i -> PHAsset? in
            set.indices.contains(i) ? set[i] : nil
        }
        library.prefetch(window, targetSize: CGSize(width: 2048, height: 2048))
    }
}
