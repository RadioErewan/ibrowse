import Photos
import SwiftData
import SwiftUI

/// Siatka nad całą biblioteką — **jedyny** widok kafelków w aplikacji.
///
/// Wcześniej były dwa: ta siatka i osobne zestawienie cech. Każde z własnym
/// zbiorem, więc kliknięcie w zestawieniu wchodziło w ocenianie i lądowało
/// w innej kolejce. Teraz kafelki są jedne, a „poruszone" to warunek filtru
/// jak każdy inny — patrz komentarz w `Filters`.
///
/// Celowo bez stronicowania i bez sztuczek: wszystkie assety wpadają do
/// `LazyVGrid`, tak jak zrobiłby to ktoś piszący to naiwnie. Jeśli to wyrobi
/// na 25 tysiącach, nie ma powodu schodzić do NSCollectionView.
struct GridView: View {
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var monitor: PerfMonitor
    @ObservedObject var filters: Filters

    /// Cechy policzone przez system — źródło podpisów na kafelkach i warunków
    /// filtru. Osobno od ocen, bo zmieniają się raz na wczytanie, a nie przy
    /// każdym naciśnięciu klawisza.
    @ObservedObject var features: FeatureIndex

    /// Zaznaczone zdjęcia. Puste znaczy „operacje dotyczą całego filtru".
    ///
    /// Na Macu **pojedynczy klik zaznacza i karmi podgląd**, `⌘` dokłada
    /// i zdejmuje pojedyncze, `⇧` zaznacza zakres od wskaźnika miejsca.
    /// Na telefonie zaznaczania nie ma: tam stuknięcie otwiera zdjęcie, bo tak
    /// działa każda galeria i nie ma czym zaznaczać.
    @Binding var selection: Set<String>

    /// Zdjęcie, na którym stoi praca — wspólne dla całej aplikacji. Siatka
    /// przewija się do niego przy wejściu, oznacza ramką i **ustawia przy
    /// każdym kliknięciu**, bo to ono karmi podgląd w trzeciej kolumnie.
    ///
    /// Bez tego powrót z oceniania lądował na początku archiwum — po godzinie
    /// pracy w 2019 roku dostawało się widok pierwszego zdjęcia z 2007.
    @Binding var focusID: String?

    /// Wejście w pełny ekran: na Macu dwuklik, na telefonie stuknięcie.
    var onOpen: (PHAsset) -> Void = { _ in }

    /// Siatka rysuje gwiazdki i filtruje po stanie oceny — puste rekordy
    /// niosące same cechy systemu nie zmieniają w niej nic, a jest ich
    /// pięćdziesiąt razy więcej niż ocen. Patrz komentarz w `CullView`.
    @Query(filter: #Predicate<Review> { $0.isRated || $0.markedForDeletion })
    private var reviews: [Review]

    @Environment(\.modelContext) private var context

    /// Pytanie przed oznaczeniem całej puli. Samo oznaczenie jest odwracalne
    /// — kasuje dopiero przegląd — ale pomyłka przy szeroko otwartym filtrze
    /// oznaczyłaby ćwierć archiwum i trzeba by to cofać ręcznie.
    @State private var confirming = false
    @State private var lastMarked: Int?
    @State private var showingDeletions = false
    @State private var hoveredDay: Date?

    private var marked: [Review] { reviews.filter(\.markedForDeletion) }

    #if os(macOS)
    /// Ten sam klucz, co suwak w belce narzędzi — `@AppStorage` trzyma oba
    /// w zgodzie bez przekazywania wiązania przez pół aplikacji.
    @AppStorage("grid.thumb") private var thumbSize = 140.0
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
        let shown = filters.apply(reviewIndex, features: features)

        return VStack(spacing: 0) {
            // Pasek pomiarowy i suwak rozmiaru to narzędzia pracy przy
            // dużym ekranie. Na telefonie zabierają jedną trzecią widoku
            // i nie dają nic w zamian — zdjęcia mają zajmować ekran.
            #if os(macOS)
            // Belka nad siatką. Suwak rozmiaru przeniósł się stąd do belki
            // narzędzi okna — tam należy, bo dotyczy widoku, nie zbioru.
            HStack(spacing: 10) {
                orderMenu
                Text(filters.order == .library
                     ? "kolejność biblioteki"
                     : "„następne” idzie tą samą kolejką")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                PerfOverlay(monitor: monitor, total: shown.count)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()
            #endif

            if filters.isActive {
                groupBar(shown)
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 3)],
                        spacing: 3,
                        pinnedViews: filters.order.isGrouped ? [.sectionHeaders] : []
                    ) {
                        if filters.order.isGrouped {
                            // Nagłówki są **podziałami w płaskiej kolejce**, nie
                            // zagnieżdżeniem. Zdjęcia idą dalej jedną listą,
                            // więc „następne" znaczy to samo co w pełnym ekranie.
                            ForEach(days(of: shown), id: \.key) { day in
                                Section {
                                    ForEach(day.assets, id: \.localIdentifier) { tile($0, in: shown, index: reviewIndex) }
                                } header: {
                                    dayHeader(day)
                                }
                            }
                        } else {
                            ForEach(shown, id: \.localIdentifier) { tile($0, in: shown, index: reviewIndex) }
                        }
                    }
                    .padding(3)
                }
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView(
                            "Nic nie pasuje",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(emptyNote)
                        )
                    }
                }
                .task(id: focusID) { await reveal(focusID, using: proxy) }
            }
        }
    }

    /// Jeden kafelek. Wyjęty z ciała widoku, bo od czasu grupowania
    /// wstawia się w dwóch miejscach naraz.
    @ViewBuilder
    private func tile(
        _ asset: PHAsset, in shown: [PHAsset], index: [String: Review]
    ) -> some View {
        Thumbnail(
            asset: asset,
            library: library,
            monitor: monitor,
            side: thumbSize,
            rating: index[asset.localIdentifier]?.stars ?? 0,
            badge: filters.badge(for: asset.localIdentifier, in: features),
            isFocus: asset.localIdentifier == focusID,
            isSelected: selection.contains(asset.localIdentifier)
        )
        // Na telefonie otwiera pojedyncze stuknięcie, bo tak działa każda
        // galeria i nie ma tu czego zaznaczać. Przewijaniu to nie przeszkadza:
        // gest dotknięcia nie odpala się, gdy palec wędruje.
        #if os(iOS)
        .onTapGesture { onOpen(asset) }
        #else
        // Kolejność ma znaczenie: dwuklik musi być wpięty **przed**
        // pojedynczym, inaczej pierwszy klik zjada gest.
        .onTapGesture(count: 2) { onOpen(asset) }
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded { toggle(asset, in: shown) }
        )
        .simultaneousGesture(
            TapGesture().modifiers(.shift).onEnded { extend(to: asset, in: shown) }
        )
        .onTapGesture { pick(asset) }
        #endif
    }

    // MARK: - Dni

    struct Day: Identifiable {
        let key: Date
        let assets: [PHAsset]
        var id: Date { key }
    }

    /// Dzieli zbiór na dni **bez zmiany kolejności** — zbiór przychodzi już
    /// posortowany, a tu powstają tylko granice. Gdyby to tu sortowało,
    /// kolejka w siatce rozjechałaby się z kolejką w pełnym ekranie.
    private func days(of assets: [PHAsset]) -> [Day] {
        let calendar = Calendar.current
        var result: [Day] = []
        var current: Date?
        var bucket: [PHAsset] = []

        for asset in assets {
            let day = calendar.startOfDay(for: asset.creationDate ?? .distantPast)
            if day != current {
                if let current { result.append(Day(key: current, assets: bucket)) }
                current = day
                bucket = []
            }
            bucket.append(asset)
        }
        if let current { result.append(Day(key: current, assets: bucket)) }
        return result
    }

    @ViewBuilder
    private func dayHeader(_ day: Day) -> some View {
        HStack(spacing: 8) {
            Text(day.key, format: .dateTime.day().month(.wide).year())
                .font(.system(size: 12, weight: .semibold))
            Text("\(day.assets.count) \(day.assets.count == 1 ? "zdjęcie" : "zdjęć")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            #if os(macOS)
            // Akcja przy najechaniu, nie na stałe — inaczej przy przewijaniu
            // dostaje się kolumnę akcentowego tekstu przez cały ekran.
            if hoveredDay == day.key {
                Button("zaznacz dzień") {
                    selection.formUnion(day.assets.map(\.localIdentifier))
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        #if os(macOS)
        .onHover { hoveredDay = $0 ? day.key : nil }
        #endif
    }

    #if os(macOS)
    /// Kolejność wyprowadzona z panelu filtru **na belkę nad siatką**.
    ///
    /// Bo to nie jest warunek — nie odsiewa niczego, tylko rozstrzyga, co
    /// znaczy „następne zdjęcie". Przestawia się w trakcie pracy dużo częściej
    /// niż rok czy cecha, więc należy jej się miejsce pod ręką.
    private var orderMenu: some View {
        Picker("kolejność", selection: $filters.order) {
            ForEach(Filters.Order.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    /// Zwykły klik zastępuje całe zaznaczenie i przestawia wskaźnik miejsca.
    private func pick(_ asset: PHAsset) {
        selection = [asset.localIdentifier]
        focusID = asset.localIdentifier
    }

    /// `⌘` dokłada i zdejmuje pojedyncze zdjęcie.
    private func toggle(_ asset: PHAsset, in shown: [PHAsset]) {
        let id = asset.localIdentifier
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
            focusID = id
        }
    }

    /// `⇧` zaznacza zakres od wskaźnika miejsca do klikniętego zdjęcia —
    /// **w kolejności zbioru roboczego**, nie w kolejności biblioteki. To jest
    /// ta sama kolejka, po której chodzi pełny ekran, więc zakres znaczy
    /// dokładnie to, co widać między dwoma kafelkami.
    private func extend(to asset: PHAsset, in shown: [PHAsset]) {
        let id = asset.localIdentifier
        guard let anchor = focusID,
              let from = shown.firstIndex(where: { $0.localIdentifier == anchor }),
              let to = shown.firstIndex(where: { $0.localIdentifier == id })
        else { return pick(asset) }

        let range = from <= to ? from...to : to...from
        selection.formUnion(shown[range].map(\.localIdentifier))
    }
    #endif

    /// Pasek pojawia się **tylko przy założonym filtrze** i to jest cała jego
    /// logika. Filtr znalazł pulę — dopiero wtedy jest co robić z pulą jako
    /// całością. Bez filtru zabierałby wysokość na przycisk bez sensu, a na
    /// telefonie wysokość jest tym, czego brakuje najbardziej.
    ///
    /// To jest pierwsza operacja na grupie w tej aplikacji. Do tej pory każda
    /// decyzja dotyczyła jednego zdjęcia, bo narzędzie było sortownikiem —
    /// a odkąd filtr potrafi wyciąć 208 zrzutów ekranu, klikanie ich po kolei
    /// przestaje mieć sens.
    @ViewBuilder
    private func groupBar(_ shown: [PHAsset]) -> some View {
        let targets = selection.isEmpty ? shown.map(\.localIdentifier) : Array(selection)

        return HStack(spacing: 10) {
            Text("\(targets.count)")
                .font(.callout.monospacedDigit().weight(.semibold))
            Text(selection.isEmpty
                 ? (shown.count == 1 ? "zdjęcie w tym filtrze" : "zdjęć w tym filtrze")
                 : "zaznaczone · \(shown.count) w tym filtrze")
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let lastMarked {
                Text("oznaczono \(lastMarked)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            // Wyjście do przeglądu **tutaj**, a nie tylko w ocenianiu.
            // Oznaczanie i kasowanie zostają rozdzielone, ale nie ma powodu,
            // żeby po oznaczeniu puli trzeba było jeszcze zmieniać tryb.
            if !marked.isEmpty {
                Button {
                    showingDeletions = true
                } label: {
                    Label("\(marked.count) do usunięcia", systemImage: "trash.fill")
                }
                .tint(.red)
                #if os(iOS)
                .font(.caption)
                #endif
            }

            if !selection.isEmpty {
                Button { selection = [] } label: { Text("odznacz") }
                    #if os(iOS)
                    .font(.caption)
                    #endif
            }

            Button(role: .destructive) {
                confirming = true
            } label: {
                Label("oznacz do usunięcia", systemImage: "trash")
            }
            .disabled(targets.isEmpty)
            #if os(iOS)
            .font(.caption)
            #endif
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: lastMarked)
        .sheet(isPresented: $showingDeletions) {
            DeletionReview(library: library, reviews: marked)
        }
        .confirmationDialog(
            "Oznaczyć \(targets.count) zdjęć do usunięcia?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Oznacz \(targets.count)", role: .destructive) {
                lastMarked = Review.mark(targets, deleted: true, in: context)
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Nic jeszcze nie zniknie. Zdjęcia trafią do przeglądu "
                 + "do usunięcia, gdzie można je odznaczyć albo skasować.")
        }
    }

    /// Pusto znaczy co innego, gdy w grze jest cecha: może nie chodzić
    /// o filtr, tylko o to, że nikt jeszcze nie wczytał pomiarów.
    private var emptyNote: String {
        guard filters.axis != .none, features.isEmpty else {
            return "Żadne zdjęcie nie spełnia warunków filtru."
        }
        #if os(macOS)
        return "Cechy leżą w bazach biblioteki Zdjęć i nikt ich jeszcze nie wczytał. "
            + "Zrób to przyciskiem w belce — wymaga Pełnego dostępu do dysku."
        #else
        return "Cechy liczy system na Macu i przyjeżdżają tu synchronizacją. "
            + "Wczytaj je na Macu, zsynchronizuj oba urządzenia i wróć tutaj."
        #endif
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
///
/// Niepubliczna dla modułu, ale nie `private`: z tego samego kafelka korzysta
/// pasek miniatur pod zdjęciem. Drugi, prawie identyczny kafelek rozjechałby
/// się z tym przy pierwszej zmianie ładowania miniatur.
struct Thumbnail: View {
    let asset: PHAsset
    let library: PhotoLibrary
    let monitor: PerfMonitor
    let side: Double
    let rating: Int

    /// Podpis w rogu — liczba, przez którą zdjęcie stoi w tym miejscu.
    /// Patrz `Filters.badge(for:in:)`.
    var badge: String? = nil

    /// Zdjęcie, na którym stoi praca. Samo przewinięcie nie wystarcza — wśród
    /// setek podobnych kafelków środek ekranu nic nie znaczy.
    let isFocus: Bool

    /// Zaznaczone do operacji na grupie. Rysowane inaczej niż wskaźnik
    /// miejsca, bo to dwie różne rzeczy: tu stoję kontra to wybrałem.
    var isSelected: Bool = false

    @State private var image: PlatformImage?
    @State private var request: PHImageRequestID?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            }
            if let badge, showsBadge {
                VStack {
                    HStack {
                        Text(badge)
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(3)
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
            if isSelected {
                Rectangle().fill(Color.accentColor.opacity(0.22))
            }
        }
        .overlay {
            // Wskaźnik miejsca wygrywa rysunkowo z zaznaczeniem, bo jest
            // jeden, a zaznaczonych bywa dwieście.
            if isFocus {
                Rectangle().strokeBorder(.yellow, lineWidth: 3)
            } else if isSelected {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
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

    /// Plakietka miary **przy najechaniu**, nie na stałe.
    ///
    /// Sto kafelków z liczbą w rogu to ściana cyfr na zdjęciach, a to ma być
    /// przeglądarka zdjęć. Miara nie jest potrzebna przy przeglądaniu — jest
    /// potrzebna przy decyzji, czyli wtedy, gdy kursor już stoi na kafelku.
    /// Na telefonie nie ma najechania, więc tam zostaje widoczna.
    private var showsBadge: Bool {
        #if os(macOS)
        hovering || isFocus
        #else
        true
        #endif
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
