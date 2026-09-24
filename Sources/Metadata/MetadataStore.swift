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
    /// Jedno połączenie na aplikację. Panel metadanych i szukanie sięgają do
    /// tych samych plików, a każde otwarcie to osobny uchwyt do gigabajtowej
    /// bazy — nie ma powodu trzymać dwóch.
    static let shared = MetadataStore()

    private var search: OpaquePointer?
    private var library: OpaquePointer?
    /// Indeks wyszukiwania od macOS 27 — `psi.sqlite` zniknął, jest `leo.sqlite`
    /// o zupełnie innym układzie. Patrz `leoTerms`.
    private var leo: OpaquePointer?
    private var cache: [String: AssetMetadata] = [:]
    private var opened = false

    /// Powód, dla którego panel jest pusty — po to, żeby zamiast milczenia
    /// pokazać, co konkretnie zrobić.
    private(set) var failure: String?

    /// Czy brak danych bierze się z nienadanego pełnego dostępu do dysku.
    /// Wydzielone z komunikatu, bo ten jeden przypadek widok obsługuje
    /// przyciskiem, a nie zdaniem — patrz `MetadataPanel`.
    private(set) var needsFullDiskAccess = false

    deinit {
        sqlite3_close(search)
        sqlite3_close(library)
        sqlite3_close(leo)
    }

    func metadata(for localIdentifier: String) -> AssetMetadata? {
        openIfNeeded()
        let uuid = String(localIdentifier.prefix(36))
        if let cached = cache[uuid] { return cached }

        var result = AssetMetadata()
        if search != nil {
            readSearchIndex(uuid: uuid, into: &result)
        } else {
            readLeoIndex(uuid: uuid, into: &result)
        }
        readExtendedAttributes(uuid: uuid, into: &result)

        cache[uuid] = result
        return result
    }

    func currentFailure() -> String? {
        openIfNeeded()
        return failure
    }

    func currentNeedsFullDiskAccess() -> Bool {
        openIfNeeded()
        return needsFullDiskAccess
    }

    /// Komplet cech jednego zdjęcia, tak jak je policzył system.
    struct Features: Sendable {
        var sharpness: Double = 0
        var exposure: Double = 0
        var faces: Int = 0
        var eyesClosed: Int = 0
        var smiles: Int = 0
        var isScreenshot: Bool = false
    }

    /// Cechy całej biblioteki, dwoma zapytaniami.
    ///
    /// Twarze idą osobno i **zagregowane do zdjęcia**, bo w bazie systemu są
    /// osobnymi wierszami — 18 tysięcy twarzy na 26 tysiącach zdjęć. Utrzymanie
    /// ich po naszej stronie jako osobnych bytów wymagałoby drugiego modelu
    /// i drugiej tabeli w pliku wymiany; policzone do liczby na zdjęciu
    /// mieszczą się w ocenie, która i tak jeździ między urządzeniami.
    ///
    /// Tracimy przez to pozycję twarzy w kadrze. Świadomie: do pytania „czy
    /// ktoś tu ma zamknięte oczy" pozycja nie jest potrzebna, a do rysowania
    /// ramek nie mamy widoku, który by je pokazywał.
    func features() -> [String: Features] {
        openIfNeeded()
        guard let library else { return [:] }

        var result: [String: Features] = [:]

        let assets = """
            SELECT a.ZUUID, m.ZBLURRINESSSCORE, m.ZEXPOSURESCORE, a.ZISDETECTEDSCREENSHOT
            FROM ZASSET a
            JOIN ZMEDIAANALYSISASSETATTRIBUTES m ON m.ZASSET = a.Z_PK
            WHERE a.ZUUID IS NOT NULL
            """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(library, assets, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let uuid = Self.text(statement, 0) else { continue }
                var entry = Features()
                entry.sharpness = sqlite3_column_double(statement, 1)
                entry.exposure = sqlite3_column_double(statement, 2)
                entry.isScreenshot = sqlite3_column_int(statement, 3) != 0
                result[uuid] = entry
            }
        }
        sqlite3_finalize(statement)

        let faces = """
            SELECT a.ZUUID, COUNT(*),
                   SUM(CASE WHEN d.ZISLEFTEYECLOSED = 1 OR d.ZISRIGHTEYECLOSED = 1 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN d.ZHASSMILE = 1 THEN 1 ELSE 0 END)
            FROM ZDETECTEDFACE d JOIN ZASSET a ON a.Z_PK = d.ZASSETFORFACE
            WHERE a.ZUUID IS NOT NULL
            GROUP BY a.ZUUID
            """
        statement = nil
        if sqlite3_prepare_v2(library, faces, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let uuid = Self.text(statement, 0) else { continue }
                var entry = result[uuid] ?? Features()
                entry.faces = Int(sqlite3_column_int(statement, 1))
                entry.eyesClosed = Int(sqlite3_column_int(statement, 2))
                entry.smiles = Int(sqlite3_column_int(statement, 3))
                result[uuid] = entry
            }
        }
        sqlite3_finalize(statement)

        return result
    }

    /// Pozostałe miary ze spisu `Measure.all`, spakowane dla każdego zdjęcia.
    ///
    /// **Sonda i odczyt w jednym.** Najpierw każda miara jest sprawdzana
    /// osobnym, pustym zapytaniem: jeśli wyrażenie się nie kompiluje, kolumny
    /// nie ma w tej wersji systemu i miara po prostu wypada. Zniknięcie
    /// kolumny po aktualizacji przestaje być awarią, a pojawienie się — jeśli
    /// dopiszemy ją do spisu — nie wymaga niczego więcej.
    ///
    /// Potem jedno zapytanie na całą bibliotekę, nie jedno na miarę. Przy
    /// czterdziestu miarach różnica to czterdzieści przebiegów po 26 tysiącach
    /// wierszy kontra jeden.
    func measures() -> [String: Data] {
        openIfNeeded()
        guard let library else { return [:] }

        let from = """
            FROM ZASSET a
            LEFT JOIN ZCOMPUTEDASSETATTRIBUTES c ON c.ZASSET = a.Z_PK
            LEFT JOIN ZMEDIAANALYSISASSETATTRIBUTES m ON m.ZASSET = a.Z_PK
            LEFT JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK
            """

        var present: [Measure] = []
        for measure in Measure.all {
            var probe: OpaquePointer?
            let sql = "SELECT \(measure.expression) \(from) LIMIT 0"
            if sqlite3_prepare_v2(library, sql, -1, &probe, nil) == SQLITE_OK {
                present.append(measure)
            }
            sqlite3_finalize(probe)
        }
        guard !present.isEmpty else { return [:] }

        let columns = present.map(\.expression).joined(separator: ", ")
        let sql = "SELECT a.ZUUID, \(columns) \(from) WHERE a.ZUUID IS NOT NULL"

        var result: [String: Data] = [:]
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(library, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let uuid = Self.text(statement, 0) else { continue }
                var values: [UInt8: Float] = [:]
                for (offset, measure) in present.enumerated() {
                    let column = Int32(offset + 1)
                    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { continue }
                    values[measure.code] = Float(sqlite3_column_double(statement, column))
                }
                if !values.isEmpty { result[uuid] = MeasurePacking.pack(values) }
            }
        }
        sqlite3_finalize(statement)
        return result
    }

    /// Ostrość policzona przez system, dla **całej biblioteki naraz**.
    ///
    /// Kolumna nazywa się `ZBLURRINESSSCORE`, ale nazwa kłamie: sprawdzone na
    /// zdjęciach z obu krańców skali — wysokie wartości to zdjęcia ostre,
    /// niskie to poruszenie i miękkość. Zwracamy więc **ostrość**, nie
    /// rozmycie, żeby nazwa po naszej stronie zgadzała się ze znaczeniem.
    ///
    /// Jedno zapytanie zamiast 26 tysięcy: odczyt po jednym zdjęciu ma sens
    /// przy panelu, gdzie patrzysz na jedno, ale nie przy zestawieniu, które
    /// z definicji sortuje wszystko.
    ///
    /// Dokładne zero odrzucamy jako **brak pomiaru**, nie zdjęcie beznadziejnie
    /// rozmyte. Takich wierszy jest kilkadziesiąt i żaden nie ma oryginału na
    /// dysku — to zdjęcia, których system jeszcze nie przeanalizował. Gdyby
    /// wpadły do zestawienia, zajęłyby sam jego początek i to one byłyby
    /// pierwszym, co zobaczysz.
    func sharpness() -> [String: Double] {
        openIfNeeded()
        guard let library else { return [:] }

        let sql = """
            SELECT a.ZUUID, m.ZBLURRINESSSCORE
            FROM ZASSET a JOIN ZMEDIAANALYSISASSETATTRIBUTES m ON m.ZASSET = a.Z_PK
            WHERE m.ZBLURRINESSSCORE IS NOT NULL AND m.ZBLURRINESSSCORE > 0
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(library, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var scores: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let uuid = Self.text(statement, 0) else { continue }
            scores[uuid] = sqlite3_column_double(statement, 1)
        }
        return scores
    }

    /// Szukanie w drugą stronę: od słowa do zdjęć.
    ///
    /// Przeszukujemy `normalized_string`, bo indeks trzyma tam wersję bez
    /// znaków diakrytycznych i wielkich liter — „Wąsy" i „wasy" trafiają w to
    /// samo. Zapytanie składa ten sam zabieg po naszej stronie.
    ///
    /// Zwykłe `LIKE` zamiast indeksu pełnotekstowego, który tu leży: 56 tysięcy
    /// wierszy przelatuje w ćwierć sekundy, a `LIKE '%x%'` znajduje też środek
    /// słowa, czego indeks przedrostkowy nie potrafi.
    /// Słowa do wyszukiwania dla **całej** biblioteki, jednym zapytaniem —
    /// dla eksportera, żeby telefon mógł szukać bez tego indeksu.
    ///
    /// Klucz: UUID zdjęcia. Wartość: `normalized_string` z indeksu Apple
    /// (już bez wielkich liter i znaków diakrytycznych, czyli dokładnie to, po
    /// czym szuka `search`), unikalne, rozdzielone nową linią. Wszystkie
    /// kategorie — miejsca, osoby, sceny, okazje — poza nazwą pliku i modelem
    /// aparatu. Słowa z OCR od trzech liter i najwyżej 150 na zdjęcie: zrzut
    /// ekranu potrafi ich mieć setki, a do znalezienia wystarczają.
    func searchTerms() -> [String: String] {
        openIfNeeded()
        guard let search else { return leo.map(Self.leoTerms) ?? [:] }

        let sql = """
            SELECT a.uuid_0, a.uuid_1, g.category, g.normalized_string
            FROM ga JOIN groups g ON g.rowid = ga.groupid
            JOIN assets a ON a.rowid = ga.assetid
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(search, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var terms: [String: [String]] = [:]
        var seen: [String: Set<String>] = [:]
        var words: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let category = Int(sqlite3_column_int(statement, 2))
            guard category != Category.filename, category != Category.cameraModel,
                  let text = Self.text(statement, 3), !text.isEmpty else { continue }
            let uuid = Self.compose(sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
            if category == Category.word {
                guard text.count >= 3, words[uuid, default: 0] < 150 else { continue }
            }
            guard seen[uuid, default: []].insert(text).inserted else { continue }
            if category == Category.word { words[uuid, default: 0] += 1 }
            terms[uuid, default: []].append(text)
        }
        return terms.mapValues { $0.joined(separator: "\n") }
    }

    /// Słowa z indeksu `leo.sqlite` (macOS 27 i nowsze).
    ///
    /// Układ ustalony na żywej bibliotece: `items` to zdjęcia (`type = 1`,
    /// `identifier` = UUID), a `lexeme_ids` — lista numerów haseł, każdy jako
    /// 4-bajtowa liczba little-endian. Hasła leżą w `lexicon` razem z kategorią.
    /// Sprawdzone na jednym zdjęciu: nazwa pliku, data, święto, miejsce i sceny
    /// zgadzały się ze sobą.
    ///
    /// Bierzemy kategorie treści: czas (1xxx), miejsca (2xxx), osoby i zwierzęta
    /// (3xxx), sceny, gatunki, zabytki, wydarzenia i tekst z OCR (4xxx), aparat,
    /// albumy i wspomnienia (6xxx–7xxx) oraz typ dokumentu (11000). Pomijamy
    /// techniczne (5xxx, 8xxx — pliki, identyfikatory, oceny; 9xxx, 10000) i
    /// **11010 — nazwiska odczytane z dokumentów tożsamości**: dane osobowe,
    /// niepotrzebne do znalezienia zdjęcia.
    /// Panel metadanych z indeksu `leo.sqlite` (macOS 27) — to samo, co
    /// `readSearchIndex` czytał z `psi.sqlite`. Układ bazy: patrz `leoTerms`.
    ///
    /// Jedno hasło ma wiele synonimów („Food", „Chow", „Meals"…); do panelu
    /// bierzemy pierwszy, czyli podstawowy. Osoby i zwierzęta mieszają imiona
    /// z ogólnikami („Person", „My Puppy") — ogólniki odpadają.
    private func readLeoIndex(uuid: String, into result: inout AssetMetadata) {
        guard let leo else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(leo, "SELECT lexeme_ids FROM items WHERE identifier = ? AND type = 1",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, uuid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var ids: [UInt32] = []
        if sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) {
            let raw = UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            for offset in stride(from: 0, to: raw.count - 3, by: 4) {
                ids.append(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        sqlite3_finalize(statement)
        guard !ids.isEmpty else { return }

        // Pierwsza treść każdego hasła, w kolejności wierszy słownika.
        var first: [UInt32: (category: Int, text: String)] = [:]
        let list = ids.map(String.init).joined(separator: ",")
        let sql = "SELECT lexeme_id, category, content FROM lexicon WHERE lexeme_id IN (\(list)) ORDER BY pk"
        guard sqlite3_prepare_v2(leo, sql, -1, &statement, nil) == SQLITE_OK else { return }
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = UInt32(sqlite3_column_int64(statement, 0))
            guard first[id] == nil, let text = Self.text(statement, 2), !text.isEmpty else { continue }
            first[id] = (Int(sqlite3_column_int(statement, 1)), text)
        }
        sqlite3_finalize(statement)

        let generic: Set<String> = ["person", "persons", "people", "pet", "pets", "animal", "animals"]
        func isName(_ text: String) -> Bool {
            let lower = text.lowercased()
            return !generic.contains(lower) && !lower.hasPrefix("my ")
        }

        var place: [(rank: Int, value: String)] = []
        for id in ids {
            guard let (category, text) = first[id] else { continue }
            switch category {
            case 3000 where isName(text): result.people.append(text)
            case 3010 where isName(text): result.pets.append(text)
            case 4000, 4010: result.scenes.append(text)
            case 4120 where text.count >= 3: result.words.append(text)
            case 1030, 4090, 2240: result.occasion.append(text)
            case 8050: result.filename = text
            case 6000 where result.camera == nil: result.camera = text
            default:
                if let rank = Self.leoPlaceOrder.firstIndex(of: category) {
                    place.append((rank, text))
                }
            }
        }
        result.place = Self.unique(place.sorted { $0.rank < $1.rank }.map(\.value))
        result.scenes = Self.unique(result.scenes)
        result.occasion = Self.unique(result.occasion)
        result.people = Self.unique(result.people)
        result.pets = Self.unique(result.pets)
        result.words = Array(Self.unique(result.words).prefix(60))
    }

    /// Miejsca od najbardziej szczegółowego: lokal, dom, zabytek, obiekt, ulica,
    /// dzielnica, miejscowość, rzeka, hrabstwo, region, kraj. Kody krajów (2170)
    /// i kontynenty (2180–2190) pomijamy — nic nie dodają.
    private static let leoPlaceOrder = [2220, 2010, 4020, 2060, 2030, 2050, 2070, 2120,
                                        2090, 2100, 2080, 2210, 2110, 2130, 2140, 2160]

    private func leoSearch(_ text: String) -> Set<String> {
        guard let leo else { return [] }
        if leoCache.map({ $0.at < .now.addingTimeInterval(-300) }) ?? true {
            leoCache = (Self.leoTerms(leo), .now)
        }
        let needle = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        return Set(leoCache?.terms.compactMap { $0.value.contains(needle) ? $0.key : nil } ?? [])
    }

    private static func leoTerms(_ leo: OpaquePointer) -> [String: String] {
        let ocr = 4120
        var lexicon: [UInt32: (text: String, isWord: Bool)] = [:]
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(leo, "SELECT lexeme_id, category, content FROM lexicon",
                              -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let category = Int(sqlite3_column_int(statement, 1))
                let included = (1000..<5000).contains(category) || (6000..<8000).contains(category)
                    || category == 11000
                guard included, let raw = text(statement, 2) else { continue }
                let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                         locale: nil).lowercased()
                guard !folded.isEmpty, category != ocr || folded.count >= 3 else { continue }
                lexicon[UInt32(sqlite3_column_int64(statement, 0))] = (folded, category == ocr)
            }
        }
        sqlite3_finalize(statement)
        guard !lexicon.isEmpty else { return [:] }

        var result: [String: String] = [:]
        guard sqlite3_prepare_v2(leo, "SELECT identifier, lexeme_ids FROM items WHERE type = 1",
                                 -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let uuid = text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let raw = UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            var seen = Set<String>()
            var terms: [String] = []
            var words = 0
            for offset in stride(from: 0, to: raw.count - 3, by: 4) {
                let id = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard let entry = lexicon[id], seen.insert(entry.text).inserted else { continue }
                if entry.isWord {
                    guard words < 150 else { continue }
                    words += 1
                }
                terms.append(entry.text)
            }
            if !terms.isEmpty { result[uuid.uppercased()] = terms.joined(separator: "\n") }
        }
        return result
    }

    /// Słowa z `leo.sqlite` trzymane w pamięci przez kilka minut — przeliczenie
    /// trwa ułamek sekundy, ale nie ma powodu robić go przy każdej literze.
    private var leoCache: (terms: [String: String], at: Date)?

    func search(_ text: String) -> Set<String> {
        openIfNeeded()
        guard text.count >= 2 else { return [] }
        // Od macOS 27 starego indeksu nie ma — bez tego szukanie po cichu
        // odpowiadało „nic nie pasuje" na wszystko.
        guard let search else { return leoSearch(text) }

        let needle = "%" + text.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: nil
        ) + "%"

        let sql = """
            SELECT a.uuid_0, a.uuid_1 FROM assets a WHERE a.rowid IN (
                SELECT ga.assetid FROM groups g JOIN ga ON ga.groupid = g.rowid
                WHERE g.normalized_string LIKE ?
            )
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(search, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(
            statement, 1, needle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )

        var found = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            found.insert(Self.compose(
                sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1)
            ))
        }
        return found
    }

    /// Odwrotność `split`: dwie liczby z powrotem w napis UUID.
    private static func compose(_ low: Int64, _ high: Int64) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var lower = UInt64(bitPattern: low)
        var upper = UInt64(bitPattern: high)
        for index in 0..<8 {
            bytes[index] = UInt8(lower & 0xFF)
            lower >>= 8
            bytes[index + 8] = UInt8(upper & 0xFF)
            upper >>= 8
        }
        let hex = bytes.map { String(format: "%02X", $0) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]]
            .map { $0.joined() }
            .joined(separator: "-")
    }

    // MARK: - Otwieranie

    private func openIfNeeded() {
        guard !opened else { return }
        opened = true

        guard let root = Self.libraryURL() else {
            failure = "Couldn't find a Photos library in ~/Pictures."
            return
        }

        search = Self.open(root.appending(path: "database/search/psi.sqlite"))
        library = Self.open(root.appending(path: "database/Photos.sqlite"))
        leo = Self.open(root.appending(path: "database/search/leo.sqlite"))

        if search == nil && library == nil && leo == nil {
            // Pełnego dostępu do dysku nie da się poprosić okienkiem — Apple
            // wymaga, żeby człowiek dodał program ręcznie. Skoro tak, to
            // przynajmniej otwieramy mu właściwy panel; patrz `MetadataPanel`.
            needsFullDiskAccess = true
            failure = "We read technique and measures straight from the Photos library databases — "
                + "PhotoKit doesn't expose them. This needs Full Disk Access."
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
#endif
