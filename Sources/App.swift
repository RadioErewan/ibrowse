import SwiftData
import SwiftUI

@main
struct IbrowseApp: App {
    private let container = IbrowseApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
    }

    /// Skład trzymamy pod własnym identyfikatorem pakietu, nigdy pod domyślną
    /// nazwą SwiftData.
    ///
    /// Aplikacja jest niesandboksowana, więc `URL.applicationSupportDirectory`
    /// wskazuje wspólny `~/Library/Application Support`, a domyślny
    /// `default.store` jest tam zajęty przez inne programy (u Radka trzyma go
    /// systemowy `icloudmail`). Własny podkatalog to jedyny sposób, żeby mieć
    /// pewność, że dotykamy wyłącznie swoich danych.
    private static var storeURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "pl.3210.ibrowse", directoryHint: .isDirectory)
            .appending(path: "ibrowse.store")
    }

    /// Na tym etapie schemat jeszcze się rusza, a oceny to dane testowe.
    /// Zamiast pisać migracje do każdej zmiany modelu, odsuwamy niezgodny
    /// skład na bok — **nigdy go nie kasując**, bo skasowanego nie da się
    /// obejrzeć, gdyby okazał się potrzebny.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([Review.self, Fingerprint.self, Series.self, SeriesStamp.self])
        let url = storeURL

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            archiveIncompatibleStore(at: url)
            return try! ModelContainer(for: schema, configurations: configuration)
        }
    }

    /// Przenosi stary skład obok, ze znacznikiem czasu. Operujemy wyłącznie
    /// wewnątrz własnego katalogu i tylko na plikach o naszej nazwie.
    private static func archiveIncompatibleStore(at url: URL) {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let archived = URL(fileURLWithPath: url.path + ".\(stamp).bak" + suffix)
            try? FileManager.default.moveItem(at: file, to: archived)
        }
    }
}

/// Rozstrzyga stan uprawnień, zanim cokolwiek pokaże. Bez zgody na bibliotekę
/// aplikacja nie ma o czym mówić, więc to jest jedyny warunek wejścia.
struct RootView: View {
    @StateObject private var library = PhotoLibrary()
    @StateObject private var monitor = PerfMonitor()
    @StateObject private var similarity = Similarity()
    @StateObject private var albums = AlbumSync()
    @StateObject private var filters = Filters()
    @Environment(\.modelContext) private var context

    @State private var mode: Mode = .grid
    @State private var showingFilters = false

    /// Jedno miejsce, w którym stoi praca — wspólne dla wszystkich trybów.
    ///
    /// Każdy tryb je zapisuje i każdy je czyta, więc przełączanie trybów
    /// nigdy nie gubi kontekstu: siatka przewija się tam, gdzie skończyło
    /// się ocenianie, a ocenianie zaczyna tam, gdzie kliknąłeś w siatce.
    @State private var focusID: String?

    enum Mode: String, CaseIterable, Identifiable {
        case grid = "siatka"
        case cull = "ocenianie"
        case pair = "parowanie"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .grid: "square.grid.2x2"
            case .cull: "star"
            case .pair: "rectangle.on.rectangle"
            }
        }
    }

    var body: some View {
        Group {
            switch library.authorization {
            case .authorized, .limited:
                if library.assets.isEmpty {
                    ProgressView("Wczytuję bibliotekę…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    main
                }
            case .notDetermined:
                Permission(
                    title: "Dostęp do biblioteki zdjęć",
                    message: "ibrowse czyta zdjęcia bezpośrednio z Twojej biblioteki. Nic nie opuszcza urządzenia.",
                    action: ("Poproś o dostęp", { Task { await library.requestAccess() } })
                )
            default:
                Permission(
                    title: "Brak dostępu",
                    message: "Odmówiono dostępu do biblioteki zdjęć. Włącz go w Ustawieniach systemowych → Prywatność i bezpieczeństwo → Zdjęcia.",
                    action: nil
                )
            }
        }
        .task { await library.start() }
        .task(id: library.assets.count) { filters.adopt(library.assets) }
        // Przy zmianie trybu zwalniamy podgrzane renditiony — inaczej
        // przejście z siatki do parowania trzyma w pamięci dwa komplety.
        .onChange(of: mode) { _, _ in library.releaseCache() }
        .task(id: library.assets.count) {
            guard !library.assets.isEmpty else { return }
            await similarity.loadGroups(context: context)
        }
        // Zmiana progu unieważnia cache przez `SeriesStamp`, więc serie
        // przeliczają się same — bez ręcznego czyszczenia czegokolwiek.
        .task(id: similarity.threshold) {
            guard !similarity.groups.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))  // po ustaniu ruchu suwakiem
            guard !Task.isCancelled else { return }
            await similarity.loadGroups(context: context)
        }
    }

    @ViewBuilder
    private var main: some View {
        #if os(iOS)
        // Na telefonie tryby idą na dolny pasek, a akcje chowają się w menu.
        // Poziomy pasek z Maca nie mieści się na szerokości kciuka: nazwy
        // trybów się ucinały, a przyciski rozlewały na trzy linie.
        TabView(selection: $mode) {
            ForEach(Mode.allCases) { item in
                NavigationStack {
                    screen(item)
                        .navigationTitle(item.rawValue)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            // Zakres lat ma własny przycisk, a nie pozycję
                            // w menu: arkusz otwierany z wnętrza menu mrugał
                            // i nie pokazywał się, bo dotknięcie zamyka menu
                            // razem z kotwicą, do której jest przypięty.
                            ToolbarItem(placement: .topBarLeading) { filterButton }
                            ToolbarItem(placement: .topBarTrailing) { actionsMenu }
                        }
                        .sheet(isPresented: $showingFilters) {
                            FilterPanel(library: library, filters: filters)
                        }
                }
                .tabItem { Label(item.rawValue, systemImage: item.icon) }
                .tag(item)
            }
        }
        #else
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)

                fingerprintControl
                Spacer()
                filterButton
                syncControl
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)

            Divider()

            screen(mode)
        }
        #endif
    }

    @ViewBuilder
    private func screen(_ mode: Mode) -> some View {
        switch mode {
        case .grid:
            GridView(
                library: library,
                monitor: monitor,
                filters: filters,
                onOpen: { asset in
                    focusID = asset.localIdentifier
                    self.mode = .cull
                },
                focusID: focusID
            )
        case .cull: CullView(library: library, filters: filters, focusID: $focusID)
        case .pair: PairView(library: library, similarity: similarity, focusID: $focusID)
        }
    }

    /// Odciski i synchronizacja to operacje rzadkie i wsadowe — na telefonie
    /// nie zasługują na stałe miejsce na ekranie.
    @ViewBuilder
    private var actionsMenu: some View {
        if similarity.isWorking {
            ProgressView().controlSize(.small)
        } else {
            Menu {
                Button {
                    Task {
                        await similarity.computeFingerprints(
                            for: library.assets, library: library, context: context
                        )
                    }
                } label: { Label("policz odciski", systemImage: "wand.and.stars") }

                Button {
                    Task {
                        _ = albums.pull(into: context)
                        await albums.push(from: context)
                    }
                } label: { Label("synchronizuj", systemImage: "arrow.triangle.2.circlepath") }

                if !similarity.groups.isEmpty {
                    Section("\(similarity.groups.count) serii") { EmptyView() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// Liczenie odcisków jest jawną, jednorazową operacją — nie chcę, żeby
    /// aplikacja po cichu mieliła całe archiwum przy pierwszym starcie.
    @ViewBuilder
    private var fingerprintControl: some View {
        if similarity.isWorking {
            HStack(spacing: 8) {
                ProgressView(value: Double(similarity.progress),
                             total: Double(max(similarity.total, 1)))
                    .frame(width: 130)
                Text("\(similarity.progress) / \(similarity.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    Task {
                        await similarity.computeFingerprints(
                            for: library.assets, library: library, context: context
                        )
                    }
                } label: {
                    Label("policz odciski", systemImage: "wand.and.stars")
                }

                if !similarity.groups.isEmpty {
                    Divider().frame(height: 16)

                    // Próg pod ręką, bo dobra wartość zależy od tego, co się
                    // fotografuje — serie startów samolotu rozjeżdżają się
                    // znacznie bardziej niż kilka ujęć tego samego drzewa.
                    Text("czułość")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $similarity.threshold, in: 0.25...0.75, step: 0.01)
                        .frame(width: 120)
                    Text(String(format: "%.2f", similarity.threshold))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("· \(similarity.groups.count) serii")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RejectionRate()
                }
            }
        }
    }
}

extension RootView {
    /// Jedno wejście do wszystkich warunków. Etykieta mówi, co jest nałożone,
    /// bo filtr założony wczoraj i zapomniany wygląda jak zniknięte archiwum.
    @ViewBuilder
    fileprivate var filterButton: some View {
        Button { showingFilters = true } label: {
            Label(filterLabel, systemImage: filters.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
            #if os(iOS)
                .font(.caption)
            #endif
        }
        #if os(macOS)
        .popover(isPresented: $showingFilters) {
            FilterPanel(library: library, filters: filters)
        }
        #endif
    }

    fileprivate var filterLabel: String {
        var parts: [String] = []

        if !filters.query.isEmpty { parts.append("„\(filters.query)”") }

        switch filters.standing {
        case .all: break
        case .rated:
            parts.append(filters.minStars == filters.maxStars
                         ? "★\(filters.minStars)"
                         : "★\(filters.minStars)–\(filters.maxStars)")
        default: parts.append(filters.standing.rawValue)
        }

        let from = filters.fromYear, to = filters.toYear
        if from > 0 || to < 9999 {
            if from > 0 && to >= 9999 { parts.append("od \(String(from))") }
            else if from <= 0 { parts.append("do \(String(to))") }
            else { parts.append(from == to ? String(from) : "\(String(from))–\(String(to))") }
        }

        return parts.isEmpty ? "filtr" : parts.joined(separator: " · ")
    }

    /// Synchronizacja jest ręczna i wsadowa. Zapis przez PhotoKit jest wolny,
    /// więc wołanie go po każdej ocenie zabiłoby tempo pracy.
    @ViewBuilder
    fileprivate var syncControl: some View {
        if albums.isSyncing {
            ProgressView().controlSize(.small)
        } else {
            Button {
                Task {
                    let seeded = albums.pull(into: context)
                    await albums.push(from: context)
                    if seeded > 0 {
                        print("zasiano \(seeded) ocen z albumów")
                    }
                }
            } label: {
                Label("synchronizuj", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Zapisuje oceny do albumów Photos i wczytuje te z innych urządzeń")
        }
    }
}

/// Ile serii odrzuciłeś jako przypadkowe. Wysoki odsetek znaczy, że czułość
/// jest za wysoka i algorytm skleja rzeczy, które nie mają ze sobą nic wspólnego.
private struct RejectionRate: View {
    @Query private var series: [Series]

    var body: some View {
        let judged = series.filter { $0.resolvedAt != nil }
        let rejected = judged.filter(\.wasRejected).count
        if judged.count >= 5 {
            let ratio = Double(rejected) / Double(judged.count)
            Text("· \(rejected)/\(judged.count) odrzuconych")
                .font(.caption)
                .foregroundStyle(ratio > 0.3 ? .orange : .secondary)
                .help(ratio > 0.3 ? "Wysoki odsetek — spróbuj obniżyć czułość" : "")
        }
    }
}

private struct Permission: View {
    let title: String
    let message: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
