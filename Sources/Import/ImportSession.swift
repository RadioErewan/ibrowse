#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Jedno zdjęcie z folderu na dysku. Identyfikatorem jest ścieżka **względna**
/// wobec wybranego folderu — przeżywa przepięcie dysku pod inną nazwą
/// i przeniesienie całego katalogu.
struct ImportItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let date: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let bytes: Int64
    /// RAW z tej samej klatki, gdy obok leży JPEG albo HEIC o tej samej
    /// nazwie. Przy samym RAW-ie to on jest `url`, a to pole zostaje puste.
    var raw: URL? = nil

    var name: String { url.lastPathComponent }

    var isRaw: Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
            .conforms(to: .rawImage) ?? false
    }
}

/// Jedna klatka na dysku: plik do oglądania i ewentualny RAW obok.
private struct Frame: Sendable {
    let primary: URL
    let raw: URL?
}

/// Decyzja o pliku przed importem. Odrzucenie znaczy „nie importuj",
/// **nigdy** „skasuj" — źródło jest tylko do odczytu (DECYZJE.md, „Importer").
struct ImportDecision: Codable, Equatable {
    var stars = 0
    var rejected = false

    var isEmpty: Bool { stars == 0 && !rejected }
}

/// Przegląd jednego folderu: skan, decyzje i ich zapis.
///
/// Decyzje leżą w pliku JSON, nie w SwiftData. Skład przy niezgodnym
/// schemacie jest odsuwany na bok, więc nowy model kosztowałby oceny
/// z biblioteki — za cenę wygody, której tu nie potrzeba.
@MainActor
final class ImportSession: ObservableObject {
    let folder: URL
    private let release: () -> Void

    @Published private(set) var items: [ImportItem] = []
    @Published private(set) var isScanning = true
    @Published private(set) var scanned = 0
    @Published private(set) var decisions: [String: ImportDecision] = [:]
    /// Postęp wczytywania miniatur w tle — patrz `prefetchThumbnails`.
    @Published private(set) var isPrefetching = false
    @Published private(set) var thumbnailsReady = 0

    private var pendingSave: Task<Void, Never>?

    private init(folder: URL, release: @escaping () -> Void) {
        self.folder = folder
        self.release = release
        decisions = Self.loadDecisions(for: folder)
    }

    deinit {
        pendingSave?.cancel()
        release()
    }

    // MARK: - Folder

    private static let bookmarkKey = "import.folderBookmark"

    static let log = Logger(subsystem: "pl.3210.lightbrary", category: "import")

    /// Zakładka **tylko do odczytu**. To nie ozdobnik: system odmówi zapisu
    /// i kasowania w tym folderze nawet wtedy, gdyby kod kiedyś spróbował.
    ///
    /// Folder otwieramy z adresu od wybieraka, nie z zakładki. Wybierak daje
    /// prawo dostępu sam w sobie; zakładka służy tylko kolejnym uruchomieniom.
    /// Gdy system odmówi zakładki, praca w tej sesji i tak idzie dalej.
    static func open(_ url: URL) -> ImportSession {
        let granted = url.startAccessingSecurityScopedResource()
        log.info("open \(url.path, privacy: .private) access \(granted)")
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil, relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            log.error("bookmark failed: \(error.localizedDescription, privacy: .public)")
        }
        return ImportSession(folder: url, release: {
            if granted { url.stopAccessingSecurityScopedResource() }
        })
    }

    /// Ostatni folder, jeśli zakładka wciąż działa. Dysk zewnętrzny bywa
    /// odpięty — wtedy po prostu wracamy do wyboru, zakładkę zostawiamy.
    static func restore() -> ImportSession? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &stale
            )
        } catch {
            log.error("bookmark resolve failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            log.error("bookmark resolved but access denied")
            return nil
        }

        if stale, let fresh = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return ImportSession(folder: url, release: { url.stopAccessingSecurityScopedResource() })
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    // MARK: - Skan

    func scan() async {
        isScanning = true
        scanned = 0
        let folder = folder
        let files = await Task.detached(priority: .userInitiated) {
            Self.frames(in: folder)
        }.value

        var found: [ImportItem] = []
        found.reserveCapacity(files.count)
        // Partiami, żeby licznik żył, a dysk zewnętrzny nie dławił się
        // setkami równoległych odczytów.
        for chunk in stride(from: 0, to: files.count, by: 32) {
            let slice = Array(files[chunk..<min(chunk + 32, files.count)])
            let read = await Task.detached(priority: .userInitiated) {
                slice.compactMap { Self.item(for: $0, in: folder) }
            }.value
            found += read
            scanned = min(chunk + 32, files.count)
        }

        // Kolejność wykonania, nie nazwy pliku: aparat i telefon numerują
        // osobno, a po złożeniu z kilku źródeł nazwy przeplatają dni.
        items = found.sorted {
            switch ($0.date, $1.date) {
            case let (a?, b?) where a != b: a < b
            case (nil, _?): false
            case (_?, nil): true
            default: $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }
        }
        isScanning = false
    }

    /// Wszystkie miniatury od razu po skanie, po kolei, w tle. Przy kilkuset
    /// zdjęciach to kilkaset megabajtów i kilkanaście sekund z dysku — w zamian
    /// przewijanie w obie strony nie czeka już na nic.
    func prefetchThumbnails() async {
        let all = items
        isPrefetching = true
        defer { isPrefetching = false }
        for (index, item) in all.enumerated() {
            guard !Task.isCancelled else { return }
            _ = await ImportImages.load(item.url, side: 400)
            // Co dziesiąte, żeby licznik nie przebudowywał okna 500 razy.
            if index % 10 == 9 || index == all.count - 1 { thumbnailsReady = index + 1 }
        }
    }

    /// Pliki obrazów zgrupowane w klatki.
    ///
    /// Aparat ustawiony na RAW+JPEG zapisuje dwa pliki o tej samej nazwie,
    /// `DSC0001.ARW` i `DSC0001.JPG`. Bez grupowania każda klatka stałaby
    /// w siatce dwa razy, a ocena jednej nie dotyczyłaby drugiej. Oglądamy
    /// JPEG albo HEIC — dekoduje się szybciej i to on jest obrazem z aparatu;
    /// RAW jedzie razem z nim przy imporcie, jak przy imporcie z karty.
    nonisolated private static func frames(in folder: URL) -> [Frame] {
        var groups: [String: (shown: URL?, raw: URL?)] = [:]
        var order: [String] = []
        for (url, isRaw) in imageFiles(in: folder) {
            let stem = url.deletingPathExtension().standardizedFileURL.path.lowercased()
            if groups[stem] == nil { order.append(stem); groups[stem] = (nil, nil) }
            if isRaw {
                if groups[stem]?.raw == nil { groups[stem]?.raw = url } else { order.append(url.path); groups[url.path] = (nil, url) }
            } else {
                if groups[stem]?.shown == nil { groups[stem]?.shown = url } else { order.append(url.path); groups[url.path] = (url, nil) }
            }
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            if let shown = group.shown { return Frame(primary: shown, raw: group.raw) }
            return group.raw.map { Frame(primary: $0, raw: nil) }
        }
    }

    nonisolated private static func imageFiles(in folder: URL) -> [(URL, Bool)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [(URL, Bool)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let type = values.contentType,
                  type.conforms(to: .image)
            else { continue }
            found.append((url, type.conforms(to: .rawImage)))
        }
        return found
    }

    nonisolated private static func item(for frame: Frame, in folder: URL) -> ImportItem? {
        let url = frame.primary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Orientacja 5–8 to obrót o 90°: plik trzyma kadr na boku.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }

        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return ImportItem(
            id: relative, url: url, date: captureDate(properties),
            pixelWidth: width, pixelHeight: height, bytes: bytes, raw: frame.raw
        )
    }

    /// Data z EXIF-u, z przesunięciem strefy, jeśli aparat je zapisał.
    /// Bez przesunięcia czytamy ją jako czas lokalny — tak samo zrobią Zdjęcia.
    nonisolated private static func captureDate(_ properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let stamp = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
                ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
                ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: stamp + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: stamp)
    }

    // MARK: - Decyzje

    func decision(for item: ImportItem) -> ImportDecision {
        decisions[item.id] ?? ImportDecision()
    }

    func setStars(_ stars: Int, for item: ImportItem) {
        update(item) { $0.stars = stars }
    }

    func toggleRejected(_ item: ImportItem) {
        update(item) { $0.rejected.toggle() }
    }

    var rejectedCount: Int {
        items.reduce(0) { $0 + (decisions[$1.id]?.rejected == true ? 1 : 0) }
    }

    private func update(_ item: ImportItem, _ change: (inout ImportDecision) -> Void) {
        var decision = decisions[item.id] ?? ImportDecision()
        change(&decision)
        decisions[item.id] = decision.isEmpty ? nil : decision
        scheduleSave()
    }

    /// Zapis odłożony o chwilę: przy szybkim odsiewie klawisz idzie co pół
    /// sekundy i nie ma sensu przepisywać pliku za każdym razem.
    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = decisions
        let file = Self.decisionsFile(for: folder)
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: file)
        }
    }

    /// Zapis natychmiast — przy zamknięciu okna albo zmianie folderu.
    func flush() {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        Self.write(decisions, to: Self.decisionsFile(for: folder))
    }

    private static func write(_ decisions: [String: ImportDecision], to file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(decisions) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static func loadDecisions(for folder: URL) -> [String: ImportDecision] {
        guard let data = try? Data(contentsOf: decisionsFile(for: folder)),
              let decoded = try? JSONDecoder().decode([String: ImportDecision].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Plik w kontenerze aplikacji, nazwany skrótem ścieżki folderu —
    /// **nigdy** obok zdjęć, bo źródła nie wolno zmieniać.
    private static func decisionsFile(for folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory
            .appending(path: "pl.3210.lightbrary/imports", directoryHint: .isDirectory)
            .appending(path: "\(name).json")
    }
}

/// Obrazy z plików, pomniejszone przez ImageIO. Miniatura zwykle siedzi
/// w samym pliku HEIC czy JPEG, więc siatka nie dekoduje pełnych klatek.
enum ImportImages {
    /// Dwie osobne pamięci: miniatur jest setki i są lekkie, pełna klatka
    /// waży kilkadziesiąt megabajtów i trzymamy tylko kilka wokół bieżącej.
    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 1500
        return cache
    }()
    private static let frames: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 6
        return cache
    }()

    private static func cache(for side: Int) -> NSCache<NSString, NSImage> {
        side <= 400 ? thumbnails : frames
    }

    static func cached(_ url: URL, side: Int) -> NSImage? {
        cache(for: side).object(forKey: key(url, side))
    }

    static func load(_ url: URL, side: Int) async -> NSImage? {
        if let hit = cached(url, side: side) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                // Wbudowana miniatura bywa malutka (160 px). Do siatki
                // wystarczy, do pełnego ekranu trzeba zdekodować klatkę.
                side <= 400 ? kCGImageSourceCreateThumbnailFromImageIfAbsent
                            : kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache(for: side).setObject(image, forKey: key(url, side)) }
        return image
    }

    private static func key(_ url: URL, _ side: Int) -> NSString {
        "\(side)|\(url.path)" as NSString
    }
}
#endif
