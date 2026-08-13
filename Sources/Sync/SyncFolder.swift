import Foundation

/// Folder wymiany wskazany przez użytkownika — zwykle katalog w iCloud Drive.
///
/// To jedyny transport dostępny na darmowym koncie deweloperskim. CloudKit
/// wymaga płatnego, a własny kontener iCloud również. Zwykły folder w Drive
/// synchronizuje się sam, nic nie kosztuje i — co ważniejsze — **użytkownik
/// widzi, co się dzieje**: może do niego zajrzeć, skopiować plik, usunąć.
///
/// Trzymamy zakładkę, nie ścieżkę. Ścieżka przestaje działać po przeniesieniu
/// katalogu albo zmianie nazwy, a na iOS nie daje w ogóle prawa dostępu.
enum SyncFolder {
    private static let key = "sync.folderBookmark"

    static func remember(_ url: URL) throws {
        #if os(macOS)
        let data = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        #else
        let data = try url.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        #endif
        UserDefaults.standard.set(data, forKey: key)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var isChosen: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

    /// Zwraca folder wraz z **obowiązkiem zwolnienia dostępu**. Na iOS bez
    /// `stopAccessing` przecieka uprawnienie i po kilku wywołaniach system
    /// przestaje ich udzielać.
    static func resolve() -> (url: URL, release: () -> Void)? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }

        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif

        guard let url = try? URL(
            resolvingBookmarkData: data, options: options,
            relativeTo: nil, bookmarkDataIsStale: &stale
        ) else { return nil }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        return (url, { url.stopAccessingSecurityScopedResource() })
    }

    static var displayName: String? {
        guard let folder = resolve() else { return nil }
        defer { folder.release() }
        return folder.url.lastPathComponent
    }

    /// Tożsamość urządzenia. Losowa i trwała — nazwa systemowa nie wystarcza,
    /// bo dwa Maki potrafią nazywać się tak samo, a zmiana nazwy nie powinna
    /// tworzyć drugiego pliku.
    static var deviceID: String {
        let key = "sync.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(String(fresh), forKey: key)
        return String(fresh)
    }

    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    static var fileName: String {
        "ibrowse-\(deviceID).\(SyncFile.fileExtension)"
    }
}

#if os(iOS)
import UIKit
#endif
