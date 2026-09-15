import Photos
import SwiftData
import SwiftUI

/// Główny widok pracy: jedno zdjęcie na pełnym ekranie, ocena z klawiatury.
///
/// Świadomie nie ma tu siatki jako trybu domyślnego — przy przeglądaniu
/// archiwum siatka kusi do przewijania, a nie do decydowania.
struct CullView: View {
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var filters: Filters
    @ObservedObject var monitor: PerfMonitor

    /// Cechy systemu — te same, po których filtruje i sortuje siatka.
    /// Ocenianie samo ich nie używa do niczego poza podpisami w pasku
    /// miniatur, ale **musi** dostać ten sam obiekt, bo inaczej liczyłoby
    /// zbiór roboczy inaczej niż siatka. Właśnie o to się to kiedyś rozbiło.
    @ObservedObject var features: FeatureIndex

    /// Wspólny wskaźnik „gdzie jestem w archiwum", jeden na całą aplikację.
    ///
    /// Działa w obie strony: dwuklik w siatce ustawia go i wchodzi tutaj,
    /// a każdy krok strzałką zapisuje go z powrotem, więc powrót do siatki
    /// trafia w to samo miejsce zamiast na początek biblioteki.
    @Binding var focusID: String?
    @Environment(\.modelContext) private var context
    /// Tylko rekordy niosące **decyzję**, nie wszystkie.
    ///
    /// Odkąd cechy systemu jadą w ocenie, rekordów jest tyle, co zdjęć —
    /// 25 tysięcy zamiast pół tysiąca. Ocenianie nie potrzebuje ani jednego
    /// z tych pustych: pyta o gwiazdki i o zaznaczenie do usunięcia. Bez tego
    /// zawężenia każde naciśnięcie klawisza przebudowywało słownik 25 tysięcy
    /// pozycji, i to po kilka razy, bo sięga po niego kilka właściwości.
    ///
    /// Zapis jest bezpieczny mimo zawężenia, bo idzie przez `Review.upsert`,
    /// które wyszukuje rekord po `assetID` niezależnie od tego zapytania.
    @Query(filter: #Predicate<Review> { $0.isRated || $0.markedForDeletion })
    private var reviews: [Review]

    @FocusState private var focused: Bool
    @State private var index = 0
    @State private var showingDeletions = false

    /// Podgląd 1:1. Przełącznik, nie przytrzymanie — przytrzymanie gubi się
    /// przy przełączeniu okna i zostawia widok w stanie, którego nikt nie
    /// zamawiał. `Z` jak w Lightroomie.
    @State private var showingLoupe = false

    /// Pasek miniatur. Zapamiętany, bo przy szybkim odsiewie zabiera wysokość,
    /// której na telefonie nie ma — ale przy przeglądaniu jest tym, po co się
    /// tu przyszło. Klawisz `T` na Macu.
    @AppStorage("cull.showingStrip") private var showingStrip = true

    #if os(macOS)
    /// Punkt, w którym stał kursor — kadr 1:1 otwiera się właśnie tam.
    @State private var loupeFocus: UnitPoint = .center
    @State private var stageSize: CGSize = .zero
    #endif

    #if os(macOS)
    @StateObject private var metadata = MetadataIndex()
    /// Domyślnie otwarty — po to powstał. Zapamiętany, bo przy szybkim
    /// odsiewie panel bywa zbędny i nie chcę go zamykać przy każdym wejściu.
    @AppStorage("cull.showingMetadata") private var showingMetadata = true
    #else
    /// Na telefonie to arkusz otwierany świadomie, więc stan jest ulotny
    /// i zawsze zaczyna zamknięty.
    @State private var showingMetadata = false
    #endif

    // MARK: - Zbiór roboczy

    private var byID: [String: Review] {
        Dictionary(reviews.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var workingSet: [PHAsset] { filters.apply(byID, features: features) }

    private var current: PHAsset? {
        let set = workingSet
        guard set.indices.contains(index) else { return nil }
        return set[index]
    }

    private var currentReview: Review? {
        current.flatMap { byID[$0.localIdentifier] }
    }

    /// Sąsiad w zbiorze roboczym, albo `nil` na końcach.
    private func neighbour(_ delta: Int) -> PHAsset? {
        let set = workingSet
        let position = index + delta
        return set.indices.contains(position) ? set[position] : nil
    }

    private var markedCount: Int {
        reviews.filter(\.markedForDeletion).count
    }

    // MARK: - Widok

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            header
            Divider()
            #endif

            stage

            if showingStrip {
                Divider()
                FilmStrip(
                    assets: workingSet,
                    index: index,
                    library: library,
                    monitor: monitor,
                    badge: { filters.badge(for: $0, in: features) },
                    onPick: { index = $0 }
                )
            }

            footer
        }
        #if os(macOS)
        // Natywny inspektor zamiast własnej kolumny z kreską: sam rysuje
        // przegrodę, pamięta szerokość, daje się przeciągać i chowa się tak
        // samo jak w każdej innej aplikacji systemu.
        .inspector(isPresented: $showingMetadata) {
            MetadataPanel(asset: current, index: metadata)
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("", selection: $filters.standing) {
                    ForEach(Filters.Standing.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)

                if markedCount > 0 {
                    Button {
                        showingDeletions = true
                    } label: {
                        Label("\(markedCount) do usunięcia", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingMetadata.toggle()
                } label: {
                    Label("metadane", systemImage: "sidebar.trailing")
                }
                .help("Panel metadanych (klawisz I)")
            }
        }
        #endif
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
        // Zmiana warunków przestawia zbiór pod nogami, więc indeks musi wrócić
        // na początek — inaczej po zawężeniu lądujesz w przypadkowym miejscu
        // albo poza zakresem.
        .onChange(of: filters.standing) { _, _ in index = 0 }
        .onChange(of: filters.base.count) { _, _ in index = 0 }
        .onChange(of: filters.feature) { _, _ in index = 0 }
        .onChange(of: filters.order) { _, _ in index = 0 }
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
        .sheet(isPresented: $showingLoupe) {
            if let current {
                #if os(macOS)
                Loupe(
                    asset: current, library: library,
                    isPresented: $showingLoupe, focus: loupeFocus
                )
                .frame(minWidth: 900, minHeight: 640)
                #else
                Loupe(asset: current, library: library, isPresented: $showingLoupe)
                #endif
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingMetadata) {
            if let current {
                MetadataSheet(asset: current)
            }
        }
        #endif
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
                // Na telefonie gest zastępuje klawiaturę: w pionie ocena,
                // w bok przewijanie. Ocena przesuwa tę samą wagę, o ten sam
                // krok co `−`/`+` na Macu, i od razu przechodzi dalej.
                SwipeCard(
                    onNudge: { direction in
                        nudge(direction)
                        step(1)
                    },
                    onStep: { step($0) },
                    library: library,
                    previous: neighbour(-1),
                    next: neighbour(+1),
                    weight: currentReview?.isRated == true ? currentReview?.weight : nil,
                    stepValue: Review.step
                ) {
                    AssetImage(asset: current, library: library)
                }
                #else
                AssetImage(asset: current, library: library)
                #endif
            } else {
                ContentUnavailableView(
                    "Pusto",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Żadne zdjęcie nie spełnia warunków filtru.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Dwuklik otwiera 1:1 także na telefonie. Nie koliduje z niczym:
        // ocenianie i przewijanie to przeciągnięcia, a pojedyncze stuknięcie
        // w tym widoku nic nie robi.
        .onTapGesture(count: 2) { if current != nil { showingLoupe = true } }
        #if os(macOS)
        // Rozmiar bierzemy z tła, a nie z nakładki: nakładka przechwyciłaby
        // dwuklik, którym otwiera się podgląd.
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { stageSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in stageSize = size }
            }
        }
        .onContinuousHover { phase in
            guard case .active(let point) = phase, let current else { return }
            loupeFocus = Self.focus(at: point, in: stageSize, for: current)
        }
        #endif
    }

    #if os(macOS)
    /// Przelicza pozycję kursora na punkt względny **zdjęcia**, a nie okna.
    ///
    /// Zdjęcie jest wpasowane w scenę z zachowaniem proporcji, więc dookoła
    /// zostają czarne pasy. Bez uwzględnienia ich szerokości kadr 1:1
    /// otwierałby się przesunięty — i to tym bardziej, im bardziej proporcje
    /// zdjęcia odbiegają od proporcji okna.
    private static func focus(at point: CGPoint, in size: CGSize, for asset: PHAsset) -> UnitPoint {
        guard size.width > 0, size.height > 0, asset.pixelHeight > 0 else { return .center }

        let photo = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        let window = size.width / size.height
        let shown = photo > window
            ? CGSize(width: size.width, height: size.width / photo)
            : CGSize(width: size.height * photo, height: size.height)

        let inset = CGPoint(
            x: (size.width - shown.width) / 2,
            y: (size.height - shown.height) / 2
        )
        return UnitPoint(
            x: min(max((point.x - inset.x) / shown.width, 0), 1),
            y: min(max((point.y - inset.y) / shown.height, 0), 1)
        )
    }
    #endif

    /// Nagłówek istnieje tylko na telefonie. Na Macu te same przełączniki
    /// siedzą w belce tytułowej, gdzie należą — własny pasek pod tytułem był
    /// wzorcem z Windows i to on najmocniej zdradzał obce pochodzenie okna.
    #if os(iOS)
    private var header: some View {
        HStack(spacing: 16) {
            // Stan oceny zostaje pod ręką, mimo że mieszka teraz w filtrze:
            // to jedyny warunek, który przestawia się w trakcie pracy, a nie
            // przed nią. Reszta warunków siedzi w panelu i tam się nie spieszy.
            Picker("", selection: $filters.standing) {
                ForEach(Filters.Standing.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            Spacer()

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
    #endif

    @ViewBuilder
    private var footer: some View {
        #if os(iOS)
        // Strzałki obok gwiazdek, bo gest w pionie trzeba najpierw odkryć —
        // a przejście dalej bez oceny musi być widoczne od pierwszego wejścia.
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                stars
                deletionMark
                Spacer()
                // Jedna ikona zamiast stałego panelu — kto chce liczby,
                // ten po nie sięga. Ekran należy się fotografii.
                Button { showingStrip.toggle() } label: {
                    Image(systemName: showingStrip
                          ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
                }
                Button { showingMetadata = true } label: {
                    Image(systemName: "info.circle")
                }
                .disabled(current == nil)
                counter
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        #else
        HStack(spacing: 18) {
            stars
            deletionMark
            Spacer()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
            counter
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Materiał paska zamiast kreski. Systemowe aplikacje oddzielają
        // dolny pasek tłem, nie linią — kreska nad stopką to kolejny
        // drobiazg, który czytało się jako obcy.
        .background(.bar)
        #endif
    }

    @ViewBuilder
    private var deletionMark: some View {
        if currentReview?.markedForDeletion == true {
            Label("do usunięcia", systemImage: "trash.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    private var counter: some View {
        Text("\(workingSet.isEmpty ? 0 : index + 1) / \(workingSet.count)")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
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
        "pociągnij w bok, żeby zobaczyć sąsiednie · w górę lepsze, w dół gorsze"
        #else
        "1–5 ocena · −/+ przesuń · Z podgląd 1:1 · X do usunięcia · T pasek · I metadane · ←/→ nawigacja"
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
        case "z", "Z":
            if current != nil { showingLoupe.toggle() }
            return .handled
        case "t", "T":
            showingStrip.toggle()
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
