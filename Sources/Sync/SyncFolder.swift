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

        // Zakładka nie do odzyskania — **zapominamy ją**, zamiast udawać, że
        // folder jest wybrany.
        //
        // Tak się dzieje po zmianie tożsamości aplikacji: zakładka wystawiona
        // poprzedniemu podpisowi przestaje obowiązywać i nigdy już nie zacznie.
        // Bez tego `isChosen` odpowiadało „tak", menu proponowało „zmień folder
        // wymiany…", a synchronizacja kończyła się prośbą o wskazanie folderu,
        // który przecież widniał jako wskazany.
        guard let url = try? URL(
            resolvingBookmarkData: data, options: options,
            relativeTo: nil, bookmarkDataIsStale: &stale
        ) else { forget(); return nil }

        guard url.startAccessingSecurityScopedResource() else { forget(); return nil }

        // Zakładka zwietrzała, ale wciąż wskazuje cel — wystawiamy ją na nowo,
        // póki mamy dostęp. Inaczej przy kolejnym uruchomieniu może już nie być
        // czego rozwiązywać.
        if stale { try? remember(url) }

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

    /// Nazwa **celowo nie idzie za nazwą aplikacji**.
    ///
    /// Plik wymiany leży w chmurze i ma po drugiej stronie drugie urządzenie,
    /// które o żadnym przemianowaniu nie wie. Zmiana nazwy pliku znaczyłaby,
    /// że każde urządzenie zaczyna pisać drugi plik obok swojego starego,
    /// a stary czyta odtąd jako cudzy — i tak w kółko, po kilkadziesiąt
    /// megabajtów na synchronizację.
    ///
    /// To samo dotyczy rozszerzenia `ibsync`. Format jest ten sam, więc
    /// przemianowanie kupowałoby wyłącznie spójność nazw, a kosztowałoby
    /// zgodność z tym, co już leży w folderze wymiany.
    private static var stem: String { "ibrowse-\(deviceID)" }

    /// **Osobne pliki, nie jeden** (od schematu 5 trzy — patrz `featuresFileName`).
    /// W jednym wspólnym pliku odciski ważyły
    /// 92% z 56 MB, a oceny — to, co realnie zmienia się przy każdej sesji
    /// oceniania — zaledwie 5%. Telefon płacił pełną cenę pliku za każdym
    /// razem, żeby dostać ułamek, który go obchodzi.
    ///
    /// Rozdział wzdłuż tej samej linii, którą już rządzi się scalanie
    /// w `LibrarySync`: odciski są deterministyczne i zmieniają się tylko
    /// wtedy, gdy jawnie każesz je policzyć; oceny zmieniają się przy każdym
    /// dotknięciu klawiatury. Dwa pliki o różnym tempie zmian, każdy
    /// przepisywany tylko wtedy, gdy jego własna treść faktycznie się zmienia
    /// — patrz `LibrarySync.exportFingerprints`.
    static var ratingsFileName: String { "\(stem)-ratings.\(SyncFile.fileExtension)" }
    static var fingerprintsFileName: String { "\(stem)-fingerprints.\(SyncFile.fileExtension)" }

    /// Trzeci plik: cechy z baz Photos. Pisze go tylko Mac, który sam je
    /// policzył — dziś aplikacja, docelowo eksporter.
    static var featuresFileName: String { "\(stem)-features.\(SyncFile.fileExtension)" }

    static var ownFileNames: Set<String> { [ratingsFileName, fingerprintsFileName, featuresFileName] }

    /// Czy plik leży w folderze — także jako nieściągnięty znacznik iCloud
    /// (`.nazwa.icloud`). Pliki zapisywane tylko przy zmianie treści muszą
    /// wrócić, gdy ktoś je skasuje; inaczej po wyczyszczeniu folderu odciski
    /// i cechy nie pojawiłyby się już nigdy.
    static func contains(_ name: String, in folder: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: folder.appending(path: name).path)
            || manager.fileExists(atPath: folder.appending(path: ".\(name).icloud").path)
    }
}

#if os(iOS)
import UIKit
#endif
