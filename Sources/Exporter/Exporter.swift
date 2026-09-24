import AppKit
import Photos
import ServiceManagement

/// Czyta bazy biblioteki Photos i zapisuje plik z cechami do folderu wymiany.
///
/// **Wyłącznie odczyt biblioteki** — to jest cały argument tego programu.
/// Pełny dostęp do dysku dostaje kod, który każdy może przeczytać na GitHubie,
/// a ten kod niczego w bibliotece nie zmienia: żadnych ocen, albumów ani
/// kasowania. Dostęp do Photos (`.readWrite` to jedyny poziom, który pozwala
/// czytać) służy tu tylko do listy zdjęć i identyfikatorów chmurowych.
///
/// Pisze wyłącznie plik `-features` pod własną nazwą — własny identyfikator
/// pakietu daje mu osobne ustawienia, więc i osobny identyfikator urządzenia.
/// Przeglądarka na tym samym Macu widzi go jako cudzy plik i czyta jak każdy
/// inny. Format i zgodność w przód: `SyncFile`.
@MainActor
final class Exporter: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var status: String?
    @Published private(set) var needsFullDiskAccess = false
    @Published private(set) var lastExport: Date?
    @Published private(set) var lastCount: Int
    @Published private(set) var folderName: String?

    private static let lastExportKey = "exporter.lastExport"
    private static let lastCountKey = "exporter.lastCount"
    private static let digestKey = "exporter.digest"

    /// Eksport po uspokojeniu się biblioteki, nie po każdej zmianie. Import
    /// z aparatu to seria zmian, a ocenianie w przeglądarce też je wywołuje —
    /// każda gwiazdka to zmiana zdjęcia.
    private static let quietPeriod: Duration = .seconds(300)

    private var observer: ExporterChangeObserver?
    private var pending: Task<Void, Never>?

    init() {
        lastExport = UserDefaults.standard.object(forKey: Self.lastExportKey) as? Date
        lastCount = UserDefaults.standard.integer(forKey: Self.lastCountKey)
        folderName = SyncFolder.displayName
        Task { await start() }
    }

    private func start() async {
        var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if access == .notDetermined {
            access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard access == .authorized || access == .limited else {
            status = "No access to the photo library. Allow it in System Settings → Privacy & Security → Photos."
            return
        }

        let observer = ExporterChangeObserver { [weak self] in
            DispatchQueue.main.async { self?.libraryChanged() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer

        // Przy starcie eksport, jeśli ostatni był dawno — program mógł nie
        // działać, gdy biblioteka się zmieniała.
        if lastExport.map({ $0 < .now.addingTimeInterval(-3600) }) ?? true {
            await export()
        }
    }

    private func libraryChanged() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: Self.quietPeriod)
            guard !Task.isCancelled else { return }
            await export()
        }
    }

    func export() async {
        guard !isWorking else { return }
        guard let folder = SyncFolder.resolve() else {
            status = "Choose the shared folder — the same one the lightbrary apps use."
            return
        }
        defer { folder.release() }
        isWorking = true
        defer { isWorking = false }

        status = "Reading the library databases…"
        let store = MetadataStore.shared
        let features = await store.features()
        let measures = await store.measures()
        let terms = await store.searchTerms()
        guard !features.isEmpty || !measures.isEmpty else {
            needsFullDiskAccess = await store.currentNeedsFullDiskAccess()
            status = await store.currentFailure() ?? "The library database has no computed measures yet."
            return
        }
        needsFullDiskAccess = false

        status = "Matching photos…"
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var localIDs: [String] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            localIDs.append(asset.localIdentifier)
        }
        let toCloud = CloudIdentity.cloudIDs(for: localIDs)

        var payload = SyncFile.Payload()
        payload.deviceName = "\(SyncFolder.deviceName) (exporter)"
        for local in localIDs {
            // Bazy kluczują zdjęcie samym UUID, bez końcówki `/L0/001`.
            let uuid = String(local.prefix(36))
            let found = features[uuid] ?? MetadataStore.Features()
            guard let cloud = toCloud[local] else { continue }
            let entry = SyncFile.Features(
                assetID: cloud, sharpness: found.sharpness, exposure: found.exposure,
                faces: found.faces, eyesClosed: found.eyesClosed, smiles: found.smiles,
                isScreenshot: found.isScreenshot, measures: measures[uuid] ?? Data(),
                terms: terms[uuid] ?? ""
            )
            if entry.carriesAnything { payload.features.append(entry) }
        }

        // Ta sama treść co ostatnio — nie piszemy. Ocenianie w przeglądarce
        // budzi eksport, a cechy się przy tym nie zmieniają; bez tego telefon
        // pobierałby kilka megabajtów po każdej sesji oceniania.
        let digest = Self.digest(of: payload.features)
        let defaults = UserDefaults.standard
        let destination = folder.url.appending(path: SyncFolder.featuresFileName)
        if digest != defaults.string(forKey: Self.digestKey)
            || !SyncFolder.contains(SyncFolder.featuresFileName, in: folder.url) {
            status = "Writing \(payload.features.count) photos…"
            let outgoing = payload
            do {
                try await Task.detached { try SyncFile.write(outgoing, to: destination) }.value
            } catch {
                status = error.localizedDescription
                return
            }
            defaults.set(digest, forKey: Self.digestKey)
        }

        lastExport = .now
        lastCount = payload.features.count
        defaults.set(lastExport, forKey: Self.lastExportKey)
        defaults.set(lastCount, forKey: Self.lastCountKey)
        status = nil
    }

    private static func digest(of features: [SyncFile.Features]) -> String {
        let rows = features.map {
            "\($0.assetID)|\($0.sharpness)|\($0.exposure)|\($0.faces)|\($0.eyesClosed)|\($0.smiles)|\($0.isScreenshot)|\($0.measures.base64EncodedString())|\($0.terms)"
        }
        return SyncFile.key(for: rows)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the shared folder the lightbrary apps use."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? SyncFolder.remember(url)
        folderName = SyncFolder.displayName
        status = nil
        Task { await export() }
    }

    func openFullDiskAccessSettings() {
        let panel = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: panel) { NSWorkspace.shared.open(url) }
    }

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            objectWillChange.send()
        }
    }
}

/// PhotoKit woła obserwatora z kolejki w tle i wymaga `NSObject`.
private final class ExporterChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ change: PHChange) {
        onChange()
    }
}
