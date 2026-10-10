#if os(macOS)
import SwiftUI
import os

/// Okno importu: przegląd folderu z dysku, zanim cokolwiek trafi do Zdjęć.
///
/// Osobne okno, nie tryb głównego. Główne żyje na `PHAsset` i ma za sobą
/// historię awarii układu; tu są zwykłe pliki i nie ma czego z nim dzielić
/// (DECYZJE.md, „Importer: plan na etapy").
struct ImportWindow: View {
    @State private var session: ImportSession?
    @State private var choosing = false
    @State private var unreachable = false

    var body: some View {
        Group {
            if let session {
                ImportBrowser(session: session, onChooseFolder: { choosing = true })
                    .id(ObjectIdentifier(session))
            } else {
                ContentUnavailableView {
                    Label("Review a folder before importing", systemImage: "folder.badge.plus")
                } description: {
                    Text(unreachable
                         ? "The last folder isn't reachable — is the drive connected?"
                         : "Pick a folder of photos, for example on an external drive. Rate them and mark the ones to leave out. Files on the disk are never changed.")
                } actions: {
                    Button("Choose Folder…") { choosing = true }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                session?.flush()
                session = ImportSession.open(url)
            case .failure(let error):
                ImportSession.log.error("picker failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        .task {
            guard session == nil else { return }
            session = ImportSession.restore()
            unreachable = session == nil && UserDefaults.standard.data(forKey: "import.folderBookmark") != nil
        }
        .onDisappear { session?.flush() }
    }
}

/// Siatka albo pełny ekran nad jednym folderem.
private struct ImportBrowser: View {
    @ObservedObject var session: ImportSession
    let onChooseFolder: () -> Void

    enum Show: String, CaseIterable, Identifiable {
        case all, keep, rejected
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: String(localized: "all")
            case .keep: String(localized: "to import")
            case .rejected: String(localized: "left out")
            }
        }
    }

    @State private var show: Show = .all
    @StateObject private var importer = PhotosImport()
    @State private var showingImport = false
    @State private var currentID: String?
    @State private var fullScreen = false
    @FocusState private var focused: Bool
    @AppStorage("import.thumb") private var thumbSize = 170.0
    /// Liczba kolumn z ostatniego układu — strzałki w pionie skaczą o wiersz.
    @State private var columns = 1

    private var shown: [ImportItem] {
        switch show {
        case .all: session.items
        case .keep: session.items.filter { session.decisions[$0.id]?.rejected != true }
        case .rejected: session.items.filter { session.decisions[$0.id]?.rejected == true }
        }
    }

    private var currentIndex: Int? {
        let list = shown
        return currentID.flatMap { id in list.firstIndex { $0.id == id } }
    }

    private var current: ImportItem? {
        currentIndex.map { shown[$0] }
    }

    var body: some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { move(-1); return .handled }
            .onKeyPress(.rightArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(fullScreen ? -1 : -columns); return .handled }
            .onKeyPress(.downArrow) { move(fullScreen ? 1 : columns); return .handled }
            .onKeyPress(.space) { move(1); return .handled }
            .onKeyPress(.return) {
                if current != nil { fullScreen.toggle() }
                return .handled
            }
            .onKeyPress(.escape) {
                guard fullScreen else { return .ignored }
                fullScreen = false
                return .handled
            }
            .onKeyPress { press in handle(press.characters) }
            .task {
                await session.scan()
                focused = true
                await session.prefetchThumbnails()
            }
            .onAppear { focused = true }
            .onChange(of: show) { _, _ in
                if current == nil { currentID = shown.first?.id }
            }
            .navigationTitle(session.folder.lastPathComponent)
            .sheet(isPresented: $showingImport, onDismiss: {
                importer.reset()
                focused = true
            }) {
                ImportSheet(session: session, importer: importer)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if fullScreen {
                        Button {
                            fullScreen = false
                        } label: {
                            Label("back to the grid", systemImage: "chevron.left")
                        }
                        .help("esc")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $show) {
                        ForEach(Show.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !fullScreen {
                        Slider(value: $thumbSize, in: 110...320) { Text("tile size") }
                            .labelsHidden()
                            .frame(width: 110)
                            .help("tile size")
                    }
                    Button(action: onChooseFolder) {
                        Label("Choose Folder…", systemImage: "folder")
                    }
                    .help("Choose another folder")
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(session.isScanning || session.pending.isEmpty)
                    .help("Copy the photos you kept into Photos")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if session.isScanning {
                ProgressView("Reading folder… \(session.scanned)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.items.isEmpty {
                ContentUnavailableView(
                    "No photos in this folder",
                    systemImage: "photo.on.rectangle",
                    description: Text("Subfolders are included.")
                )
            } else if fullScreen, let item = current {
                ImportViewer(
                    item: item,
                    decision: session.decision(for: item),
                    neighbours: neighbours
                )
            } else {
                grid
            }
            footer
        }
    }

    private var neighbours: [ImportItem] {
        guard let index = currentIndex else { return [] }
        let list = shown
        return [index + 1, index - 1, index + 2].compactMap { list.indices.contains($0) ? list[$0] : nil }
    }

    private var grid: some View {
        GeometryReader { geometry in
            let spacing = 6.0
            let count = max(1, Int((geometry.size.width - 2 * spacing + spacing) / (thumbSize + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: count),
                        spacing: spacing
                    ) {
                        ForEach(shown) { item in
                            ImportTile(
                                item: item,
                                decision: session.decision(for: item),
                                isCurrent: item.id == currentID
                            )
                            .id(item.id)
                            .onTapGesture(count: 2) {
                                currentID = item.id
                                fullScreen = true
                            }
                            .onTapGesture {
                                currentID = item.id
                                focused = true
                            }
                        }
                    }
                    .padding(spacing)
                }
                .onChange(of: currentID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
                .onAppear {
                    columns = count
                    if let currentID { proxy.scrollTo(currentID, anchor: .center) }
                }
                .onChange(of: count) { _, new in columns = new }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            let total = session.items.count
            let rejected = session.rejectedCount
            let imported = session.importedCount
            Text("\(session.pending.count) to import · \(rejected) left out · \(imported) in Photos")
                .monospacedDigit()
            if let item = current {
                Divider().frame(height: 12)
                Text(item.raw.map { "\(item.name) + \($0.pathExtension.uppercased())" } ?? item.name)
                    .lineLimit(1).truncationMode(.middle)
                if let date = item.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                Text("\(item.pixelWidth)×\(item.pixelHeight)")
                    .monospacedDigit()
            }
            Spacer()
            if session.isPrefetching {
                ProgressView(
                    value: Double(session.thumbnailsReady),
                    total: Double(max(total, 1))
                )
                .frame(width: 90)
                .controlSize(.small)
                Text("thumbnails \(session.thumbnailsReady)/\(total)")
                    .monospacedDigit()
                Divider().frame(height: 12)
            }
            Text("1–5 rate · 0 clear · X leave out · ←/→ navigate · return full screen")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Akcje

    private func move(_ delta: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        guard let index = currentIndex else {
            currentID = list.first?.id
            return
        }
        currentID = list[min(max(index + delta, 0), list.count - 1)].id
    }

    private func handle(_ characters: String) -> KeyPress.Result {
        guard let key = characters.first, let item = current else { return .ignored }
        switch key {
        case "0"..."5":
            let stars = Int(String(key)) ?? 0
            keepingPlace { session.setStars(stars, for: item) }
            move(1)
            return .handled
        case "x", "X":
            // Dalej, jak przy gwiazdkach — decyzja Radka po pierwszym odsiewie
            // całego folderu. Gdy filtr sam wyjął zdjęcie, na jego miejscu
            // już stoi następne i drugi krok by je przeskoczył.
            let id = item.id
            keepingPlace { session.toggleRejected(item) }
            if currentID == id { move(1) }
            return .handled
        default:
            return .ignored
        }
    }

    /// Decyzja przy filtrze potrafi wyjąć zdjęcie ze zbioru — wtedy stajemy
    /// na tym, które weszło na jego miejsce, a nie na początku listy.
    private func keepingPlace(_ change: () -> Void) {
        let index = currentIndex
        change()
        let list = shown
        guard let index, !list.contains(where: { $0.id == currentID }) else { return }
        currentID = list.isEmpty ? nil : list[min(index, list.count - 1)].id
        if list.isEmpty { fullScreen = false }
    }
}

/// Arkusz importu: nazwa albumu, postęp i wynik.
private struct ImportSheet: View {
    @ObservedObject var session: ImportSession
    @ObservedObject var importer: PhotosImport
    @Environment(\.dismiss) private var dismiss
    @State private var album = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch importer.phase {
            case .idle:
                Text("Import \(session.pending.count) photos into Photos")
                    .font(.headline)
                TextField("Album", text: $album)
                    .textFieldStyle(.roundedBorder)
                Text("Copies go into Photos with their stars. Files on the disk stay as they are; photos you left out aren't imported. Photos already imported are skipped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Import") {
                        Task { await importer.run(session, album: album) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .running(let done, let total):
                Text("Importing…").font(.headline)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(done) / \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .finished(let imported, let failed, let title):
                Text("Imported \(imported) photos").font(.headline)
                if !title.isEmpty {
                    Text("Album: \(title)").foregroundStyle(.secondary)
                }
                if failed > 0 {
                    Text("\(failed) files couldn't be imported and stay marked as to import.")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Text("Import failed").font(.headline)
                Text(message).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(importer.isRunning)
        .onAppear { album = session.folder.lastPathComponent }
    }
}

/// Kafelek siatki: miniatura z gwiazdkami i znakiem pominięcia.
private struct ImportTile: View {
    let item: ImportItem
    let decision: ImportDecision
    let isCurrent: Bool

    @State private var image: NSImage?

    /// Obraz z pamięci od **pierwszej klatki**, nie z zadania po pojawieniu
    /// się. Siatka tworzy kafelek od nowa przy każdym powrocie na ekran,
    /// a zadanie rusza klatkę później — wcześniej mignęło wtedy kółko, choć
    /// miniatura dawno była w pamięci, i wyglądało to na ponowne wczytanie.
    init(item: ImportItem, decision: ImportDecision, isCurrent: Bool) {
        self.item = item
        self.decision = decision
        self.isCurrent = isCurrent
        _image = State(initialValue: ImportImages.cached(item.url, side: 400))
    }

    /// Znaczek RAW na kafelku — przy parze od razu widać, że idą dwa pliki.
    private var kind: String? {
        if item.raw != nil {
            return "RAW+\(item.url.pathExtension.uppercased())"
        }
        return item.isRaw ? "RAW" : nil
    }

    var body: some View {
        Color.black
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .opacity(decision.rejected ? 0.35 : 1)
            .overlay(alignment: .bottomLeading) {
                if decision.stars > 0 {
                    Text(String(repeating: "★", count: decision.stars))
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if let kind {
                    Text(kind)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if decision.imported != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .green)
                        .padding(5)
                        .help("Already in Photos")
                }
            }
            .overlay(alignment: .topTrailing) {
                if decision.rejected {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .red)
                        .padding(5)
                }
            }
            .overlay {
                if isCurrent {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .task(id: item.id) {
                if image == nil { image = await ImportImages.load(item.url, side: 400) }
            }
    }
}

/// Pełny ekran: jedno zdjęcie w rozdzielczości ekranu.
private struct ImportViewer: View {
    let item: ImportItem
    let decision: ImportDecision
    /// Sąsiedzi do wczytania z wyprzedzeniem — przy dysku zewnętrznym
    /// dekodowanie HEIC trwa dość, żeby było je widać przy każdym kroku.
    let neighbours: [ImportItem]

    /// Bok ekranu w pikselach, z górnym limitem. Pełny plik z aparatu bywa
    /// dwa razy większy niż ekran i nic więcej z niego nie widać.
    private static let side = 3200

    @State private var image: NSImage?
    @State private var shownID: String?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
                Text(decision.stars > 0
                     ? String(repeating: "★", count: decision.stars)
                     : "☆")
                    .foregroundStyle(.yellow)
                if decision.rejected {
                    Label("left out", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.title3)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(16)
        }
        .task(id: item.id) {
            // Najpierw miniatura z siatki, żeby krok był natychmiastowy;
            // pełna klatka dochodzi, gdy dysk ją odda.
            image = ImportImages.cached(item.url, side: Self.side)
                ?? ImportImages.cached(item.url, side: 400)
            if let full = await ImportImages.load(item.url, side: Self.side), !Task.isCancelled {
                image = full
            }
            for next in neighbours {
                guard !Task.isCancelled else { return }
                _ = await ImportImages.load(next.url, side: Self.side)
            }
        }
    }
}
#endif
