#if os(macOS)
import Foundation
import Photos
import SQLite3

/// Metadane, których PhotoKit nie oddaje.
///
/// `PHAsset` zna datę, współrzędne i wymiary — i na tym koniec. Nazwy miejsc,
/// rozpoznane osoby, etykiety scen, odczytany tekst i cała technika zdjęcia
/// leżą w bazach biblioteki, do których nie ma publicznego API.
struct AssetMetadata: Sendable {
    var filename: String?
    var people: [String] = []
    var pets: [String] = []
    /// Od najbardziej szczegółowego do najogólniejszego.
    var place: [String] = []
    var scenes: [String] = []
    var occasion: [String] = []
    var words: [String] = []

    var camera: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var shutter: Double?
    var focalLength: Double?
    var flash: Bool?

    var isEmpty: Bool {
        filename == nil && people.isEmpty && place.isEmpty && scenes.isEmpty
            && occasion.isEmpty && words.isEmpty && camera == nil
    }
}

/// Czyta biblioteki Zdjęć **tylko do odczytu** i tylko na macOS.
///
/// To świadome odstępstwo od zasady „PhotoKit, nie SQLite". Zasada broni
/// fundamentu: oceny, serie i usuwanie idą wyłącznie przez oficjalne API,
/// bo mają działać na obu platformach i przetrwać zmianę schematu. Panel
/// metadanych jest dodatkiem — gdy Apple przestawi kolumny, panel zgaśnie
/// i nic poza nim się nie stanie.
///
/// Baz **nie kopiujemy**: `Photos.sqlite` ma gigabajt, a wolnego miejsca na
/// dysku jest tu mniej niż samego archiwum. Otwieramy w miejscu, w trybie
/// `mode=ro`; jeśli to nie przejdzie (bywa, gdy Zdjęcia nie działają i nie ma
/// pliku `-shm`), schodzimy na `immutable=1`, który czyta sam plik główny.
actor MetadataStore {
    private var search: OpaquePointer?
    private var library: OpaquePointer?
    private var cache: [String: AssetMetadata] = [:]
    private var opened = false

    /// Powód, dla którego panel jest pusty — po to, żeby zamiast milczenia
    /// pokazać, co konkretnie zrobić.
    private(set) var failure: String?

    deinit {
        sqlite3_close(search)
        sqlite3_close(library)
    }

    func metadata(for localIdentifier: String) -> AssetMetadata? {
        openIfNeeded()
        let uuid = String(localIdentifier.prefix(36))
        if let cached = cache[uuid] { return cached }

        var result = AssetMetadata()
        readSearchIndex(uuid: uuid, into: &result)
        readExtendedAttributes(uuid: uuid, into: &result)

        cache[uuid] = result
        return result
    }

    func currentFailure() -> String? {
        openIfNeeded()
        return failure
    }

    // MARK: - Otwieranie

    private func openIfNeeded() {
        guard !opened else { return }
        opened = true

        guard let root = Self.libraryURL() else {
            failure = "Nie znalazłem biblioteki Zdjęć w ~/Pictures."
            return
        }

        search = Self.open(root.appending(path: "database/search/psi.sqlite"))
        library = Self.open(root.appending(path: "database/Photos.sqlite"))

        if search == nil && library == nil {
            failure = """
                Brak dostępu do baz biblioteki Zdjęć. Ustawienia systemowe → \
                Prywatność i bezpieczeństwo → Pełny dostęp do dysku → dodaj ibrowse.
                """
        }
    }

    /// Domyślna lokalizacja, a gdy jej nie ma — pierwszy pakiet w ~/Pictures.
    private static func libraryURL() -> URL? {
        let pictures = URL.picturesDirectory
        let standard = pictures.appending(path: "Photos Library.photoslibrary")
        if FileManager.default.fileExists(atPath: standard.path) { return standard }

        let contents = try? FileManager.default.contentsOfDirectory(
            at: pictures, includingPropertiesForKeys: nil
        )
        return contents?.first { $0.pathExtension == "photoslibrary" }
    }

    private static func open(_ url: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        for parameters in ["?mode=ro", "?immutable=1"] {
            var handle: OpaquePointer?
            let uri = url.absoluteString + parameters
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            if sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, handle != nil {
                // Otwarcie potrafi się udać, a pierwszy odczyt dopiero pokazać,
                // że dziennika WAL nie da się przeczytać. Sprawdzamy od razu.
                if sqlite3_exec(handle, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK {
                    return handle
                }
            }
            sqlite3_close(handle)
        }
        return nil
    }

    // MARK: - Indeks wyszukiwania

    /// Kategorie w `psi.sqlite`. Numery są nieudokumentowane — ustalone
    /// przez porównanie zawartości z tym, co pokazuje aplikacja Zdjęcia.
    private enum Category {
        static let poi = 1, street = 2, neighbourhood = 3, locality = 5
        static let county = 7, area = 9, region = 10, country = 12
        static let water = 14
        static let venueKind = 1003, holiday = 1103
        static let word = 1203
        static let person = 1300, pet = 1330
        static let scene = 1500, moment = 1600
        static let business = 1700, businessKind = 1701
        static let building = 1520
        static let filename = 2100, cameraModel = 2300

        /// Kolejność wyświetlania miejsca: od punktu do kraju.
        static let placeOrder = [poi, building, street, neighbourhood, locality,
                                 water, area, county, region, country]
    }

    private func readSearchIndex(uuid: String, into result: inout AssetMetadata) {
        guard let search, let (low, high) = Self.split(uuid: uuid) else { return }

        let sql = """
            SELECT g.category, g.content_string, g.score
            FROM ga JOIN groups g ON g.rowid = ga.groupid
            WHERE ga.assetid = (SELECT rowid FROM assets WHERE uuid_0 = ? AND uuid_1 = ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(search, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, low)
        sqlite3_bind_int64(statement, 2, high)

        var place: [(rank: Int, value: String)] = []
        var scenes: [(score: Double, value: String)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let category = Int(sqlite3_column_int(statement, 0))
            guard let text = Self.text(statement, 1) else { continue }
            let score = sqlite3_column_double(statement, 2)

            switch category {
            case Category.person: result.people.append(text)
            case Category.pet: result.pets.append(text)
            case Category.scene: scenes.append((score, text))
            case Category.filename: result.filename = text
            case Category.cameraModel: result.camera = text
            case Category.word where text.count >= 3: result.words.append(text)
            case Category.moment, Category.holiday, Category.business,
                 Category.businessKind, Category.venueKind:
                result.occasion.append(text)
            default:
                if let rank = Category.placeOrder.firstIndex(of: category) {
                    place.append((rank, text))
                }
            }
        }

        // Etykiety schodzą od najpewniejszej — pierwsze pięć niesie prawie całą
        // treść zdjęcia, reszta to ogólniki w rodzaju „Outdoor".
        result.scenes = scenes.sorted { $0.score > $1.score }.map(\.value)
        result.place = place.sorted { $0.rank < $1.rank }.map(\.value)
        result.occasion = Self.unique(result.occasion)
        result.people = Self.unique(result.people)
        result.words = Array(Self.unique(result.words).prefix(60))
    }

    /// UUID w `psi.sqlite` leży jako dwie liczby: bajty 0–7 i 8–15 czytane
    /// jako little-endian. Zweryfikowane na 40 zdjęciach — 38 trafień, dwa
    /// braki to zdjęcia dodane po ostatniej indeksacji.
    private static func split(uuid: String) -> (Int64, Int64)? {
        guard let value = UUID(uuidString: uuid) else { return nil }
        let bytes = withUnsafeBytes(of: value.uuid) { Array($0) }
        func int64(_ slice: ArraySlice<UInt8>) -> Int64 {
            slice.reversed().reduce(Int64(0)) { ($0 << 8) | Int64($1) }
        }
        return (int64(bytes[0..<8]), int64(bytes[8..<16]))
    }

    /// Napisy w indeksie są zakończone bajtem zerowym i bywają obudowane
    /// spacjami — bez czyszczenia „Sky\0" nie zrówna się z niczym.
    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        let cleaned = String(cString: raw)
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Technika zdjęcia

    /// Tu UUID jest zwykłym napisem i jest zaindeksowany, więc odczyt kosztuje
    /// ułamek milisekundy mimo gigabajtowego pliku.
    private func readExtendedAttributes(uuid: String, into result: inout AssetMetadata) {
        guard let library else { return }

        let sql = """
            SELECT e.ZCAMERAMODEL, e.ZLENSMODEL, e.ZISO, e.ZAPERTURE,
                   e.ZSHUTTERSPEED, e.ZFOCALLENGTH, e.ZFLASHFIRED
            FROM ZASSET a JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK
            WHERE a.ZUUID = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(library, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, uuid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return }

        if let model = Self.text(statement, 0) { result.camera = model }
        result.lens = Self.text(statement, 1)
        if sqlite3_column_type(statement, 2) != SQLITE_NULL {
            result.iso = Int(sqlite3_column_int(statement, 2))
        }
        if sqlite3_column_type(statement, 3) != SQLITE_NULL {
            result.aperture = sqlite3_column_double(statement, 3)
        }
        if sqlite3_column_type(statement, 4) != SQLITE_NULL {
            result.shutter = sqlite3_column_double(statement, 4)
        }
        if sqlite3_column_type(statement, 5) != SQLITE_NULL {
            result.focalLength = sqlite3_column_double(statement, 5)
        }
        if sqlite3_column_type(statement, 6) != SQLITE_NULL {
            result.flash = sqlite3_column_int(statement, 6) != 0
        }
    }
}

/// Warstwa dla widoku: trzyma metadane bieżącego zdjęcia i pilnuje, żeby
/// szybkie przeskakiwanie strzałką nie zostawiło na ekranie opisu poprzedniego.
@MainActor
final class MetadataIndex: ObservableObject {
    @Published private(set) var current: AssetMetadata?
    @Published private(set) var failure: String?

    private let store = MetadataStore()

    func load(_ asset: PHAsset?) async {
        guard let asset else { current = nil; return }
        let identifier = asset.localIdentifier
        let loaded = await store.metadata(for: identifier)
        // Odczyt jest asynchroniczny, a zdjęcie mogło się w tym czasie zmienić.
        guard identifier == asset.localIdentifier else { return }
        current = loaded
        failure = await store.currentFailure()
    }
}
#endif
