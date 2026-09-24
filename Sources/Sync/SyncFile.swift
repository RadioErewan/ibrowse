import CryptoKit
import Foundation
import SQLite3

/// Plik wymiany między urządzeniami — **jeden na urządzenie**.
///
/// To jest sedno tego rozwiązania. Wspólny plik, do którego pisze telefon
/// i Mac, prędzej czy później rozjedzie się w iCloud Drive: usługa rozstrzyga
/// równoległe zapisy tworząc kopie konfliktowe, a wtedy trzeba by je scalać
/// ręcznie. Przy podziale na pliki per urządzenie **każdy ma dokładnie jednego
/// zapisującego**, więc konflikt nie ma jak powstać. Scalanie odbywa się przy
/// czytaniu, gdzie i tak musi.
///
/// Formatem jest SQLite, a nie JSON, z powodu odcisków: 25 tysięcy wektorów po
/// 1536 bajtów to 39 MB danych binarnych. W base64 urosłoby to o jedną trzecią
/// i wymagało wczytania całości do pamięci przed pierwszym odczytem.
///
/// Świadome ograniczenie: **nie wymieniamy samych zdjęć**. Plik zakłada, że oba
/// urządzenia widzą tę samą bibliotekę iCloud.
///
/// Wszystkie identyfikatory w pliku są **chmurowe** (`PHCloudIdentifier`),
/// nigdy lokalne. `localIdentifier` jest lokalny — nazwa nie kłamie — i to samo
/// zdjęcie ma inny na Macu niż na telefonie. Pierwsza wersja tego nie
/// uwzględniała i skutek był podręcznikowy: odciski z Maca dosiadły się obok
/// tych z telefonu, nie trafiając w ani jedno wspólne zdjęcie.
struct SyncFile {

    /// Wersja formatu. Gdy się zmieni, starsze pliki są pomijane przy czytaniu
    /// zamiast wczytywane błędnie — cudzy plik z przyszłości to jedyny scenariusz,
    /// w którym cicha porażka byłaby gorsza od głośnej.
    /// Wersja 2: identyfikatory są **chmurowe**, nie lokalne. Pliki w wersji 1
    /// są cicho pomijane, i słusznie — wpisy w nich wskazują na identyfikatory
    /// obcego urządzenia, więc wczytane wyrządziłyby szkodę zamiast pożytku.
    /// Wersja 3: ocena niesie **cechy policzone przez system** — ostrość,
    /// ekspozycję, twarze. Czytane są tylko na macOS, ale jadą wszędzie, bo
    /// telefon nie ma jak ich policzyć. Starsza wersja aplikacji pominie taki
    /// plik w całości; to znaczy, że oba urządzenia trzeba zaktualizować razem.
    /// Wersja 4 dołożyła spakowane miary. Czytamy 3 i 4 — starszy plik po
    /// prostu ich nie niesie, a przy ścisłej równości telefon ze starszą wersją
    /// i Mac z nowszą przestawały się widzieć, dopóki oba nie dostały
    /// aktualizacji.
    /// Wersja 5: **decyzje osobno od danych wygenerowanych.** Tabela ocen niesie
    /// już tylko decyzje; cechy mają własną tabelę i własny plik (`-features`),
    /// a oznaczenia do skasowania wypadły — jedzie nimi album w Photos. Patrz
    /// DECYZJE.md, „Pliki wymiany: wygenerowane osobno od decyzji".
    ///
    /// Od wersji 5 obowiązuje **zgodność w przód**. Plik niesie `minReader` —
    /// najstarszą wersję czytnika, która go zrozumie — a kolumny czytamy po
    /// nazwie: nieznane pomijamy, brakujące dostają wartość domyślną. Dopisanie
    /// kolumny nie wymaga więc podbicia `minReader`; tylko zerwanie zgodności.
    /// To jest warunek podziału na osobno wydawane programy: przeglądarka ze
    /// sklepu nie może oślepnąć, gdy eksporter z GitHuba dołoży pole.
    static let schema = 5
    static let minReader = 5
    /// Najnowsza wersja, którą ten czytnik rozumie.
    static let readerVersion = 5
    /// Starszych nie czytamy wcale: do wersji 2 identyfikatory były lokalne.
    static let oldestReadable = 3
    static let fileExtension = "ibsync"

    // MARK: - Przenoszone dane

    /// Sama decyzja. Scalana regułą „wygrywa nowszy" po `updatedAt`.
    struct Rating: Sendable {
        var assetID: String
        var weight: Double
        var isRated: Bool
        var judgements: Int
        var updatedAt: Date
    }

    /// Cechy policzone przez system — **nie decyzja**, więc bez `updatedAt`.
    /// Zero znaczy „nie policzono": pusty pomiar nigdy nie kasuje cudzego.
    struct Features: Sendable {
        var assetID: String
        var sharpness: Double = 0
        var exposure: Double = 0
        var faces: Int = 0
        var eyesClosed: Int = 0
        var smiles: Int = 0
        var isScreenshot: Bool = false
        var measures: Data = Data()

        var carriesAnything: Bool {
            sharpness > 0 || exposure > 0 || faces > 0 || isScreenshot || !measures.isEmpty
        }
    }

    struct Print: Sendable {
        var assetID: String
        var vector: Data
        var takenAt: Date
    }

    /// Rozstrzygnięcie serii, kluczowane **składem**, a nie identyfikatorem.
    ///
    /// Każde urządzenie liczy serie u siebie, więc żaden wspólny identyfikator
    /// nie istnieje. Ale przy tych samych odciskach i tym samym progu obie
    /// strony dostają identyczne grupy, więc skład jest naturalnym kluczem —
    /// i sam z siebie unieważnia rozstrzygnięcie, gdy grupa się zmieni.
    struct Verdict: Sendable {
        var key: String
        var resolvedAt: Date?
        var wasRejected: Bool
        var championID: String?
        var challengerIndex: Int
    }

    struct Payload: Sendable {
        var ratings: [Rating] = []
        var features: [Features] = []
        var prints: [Print] = []
        var verdicts: [Verdict] = []
        var writtenAt: Date = .now
        var deviceName: String = ""
    }

    /// Skrót ze składu serii. Kolejność sortowana, żeby ta sama grupa dała ten
    /// sam klucz niezależnie od tego, w jakiej kolejności ją złożono.
    static func key(for members: [String]) -> String {
        let joined = members.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Zapis

    static func write(_ payload: Payload, to url: URL) throws {
        // Piszemy obok i podmieniamy na końcu. iCloud Drive zaczyna wysyłać
        // plik, gdy tylko ten się pojawi — bez tego drugie urządzenie mogłoby
        // pobrać połowę zapisu.
        let temporary = url.deletingLastPathComponent()
            .appending(path: url.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: temporary)

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            temporary.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil
        ) == SQLITE_OK else { throw SyncError.cannotWrite }
        defer { sqlite3_close(db) }

        exec(db, """
            PRAGMA journal_mode=OFF;
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE rating(assetID TEXT PRIMARY KEY, weight REAL, isRated INT,
                                judgements INT, updatedAt REAL);
            CREATE TABLE feature(assetID TEXT PRIMARY KEY, sharpness REAL, exposure REAL,
                                 faces INT, eyesClosed INT, smiles INT, screenshot INT,
                                 measures BLOB);
            CREATE TABLE print(assetID TEXT PRIMARY KEY, vector BLOB, takenAt REAL);
            CREATE TABLE verdict(key TEXT PRIMARY KEY, resolvedAt REAL, wasRejected INT,
                                 championID TEXT, challengerIndex INT);
            """)

        exec(db, "BEGIN")
        insertMeta(db, "schema", String(schema))
        insertMeta(db, "minReader", String(minReader))
        insertMeta(db, "writtenAt", String(payload.writtenAt.timeIntervalSince1970))
        insertMeta(db, "device", payload.deviceName)

        // Zapytanie kompilujemy **raz na tabelę**, nie raz na wiersz.
        // Pierwsza wersja przygotowywała je w pętli i zapis 25 tysięcy
        // odcisków trwał pół minuty — to nie dysk był wąskim gardłem, tylko
        // dwadzieścia pięć tysięcy kompilacji tego samego SQL-a.
        repeating(db, "INSERT OR REPLACE INTO rating VALUES(?,?,?,?,?)", payload.ratings) {
            statement, rating in
            bind(statement, 1, rating.assetID)
            sqlite3_bind_double(statement, 2, rating.weight)
            sqlite3_bind_int(statement, 3, rating.isRated ? 1 : 0)
            sqlite3_bind_int(statement, 4, Int32(rating.judgements))
            sqlite3_bind_double(statement, 5, rating.updatedAt.timeIntervalSince1970)
        }

        repeating(db, "INSERT OR REPLACE INTO feature VALUES(?,?,?,?,?,?,?,?)", payload.features) {
            statement, features in
            bind(statement, 1, features.assetID)
            sqlite3_bind_double(statement, 2, features.sharpness)
            sqlite3_bind_double(statement, 3, features.exposure)
            sqlite3_bind_int(statement, 4, Int32(features.faces))
            sqlite3_bind_int(statement, 5, Int32(features.eyesClosed))
            sqlite3_bind_int(statement, 6, Int32(features.smiles))
            sqlite3_bind_int(statement, 7, features.isScreenshot ? 1 : 0)
            _ = features.measures.withUnsafeBytes { raw in
                sqlite3_bind_blob(
                    statement, 8, raw.baseAddress, Int32(features.measures.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        }

        repeating(db, "INSERT OR REPLACE INTO print VALUES(?,?,?)", payload.prints) {
            statement, print in
            bind(statement, 1, print.assetID)
            _ = print.vector.withUnsafeBytes { raw in
                sqlite3_bind_blob(
                    statement, 2, raw.baseAddress, Int32(print.vector.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            sqlite3_bind_double(statement, 3, print.takenAt.timeIntervalSince1970)
        }

        repeating(db, "INSERT OR REPLACE INTO verdict VALUES(?,?,?,?,?)", payload.verdicts) {
            statement, verdict in
            bind(statement, 1, verdict.key)
            if let resolved = verdict.resolvedAt {
                sqlite3_bind_double(statement, 2, resolved.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_int(statement, 3, verdict.wasRejected ? 1 : 0)
            if let champion = verdict.championID {
                bind(statement, 4, champion)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_int(statement, 5, Int32(verdict.challengerIndex))
        }
        exec(db, "COMMIT")
        sqlite3_close(db)
        db = nil

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    // MARK: - Odczyt

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    static func read(_ url: URL) -> Payload? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        // Pliki sprzed wersji 5 nie niosą `minReader`; wtedy wymagają czytnika
        // co najmniej w swojej wersji, co ten spełnia.
        guard let raw = meta(db, "schema"), let version = Int(raw),
              version >= oldestReadable else { return nil }
        let required = meta(db, "minReader").flatMap(Int.init) ?? version
        guard required <= readerVersion else { return nil }

        var payload = Payload()
        payload.deviceName = meta(db, "device") ?? "?"
        if let written = meta(db, "writtenAt"), let seconds = Double(written) {
            payload.writtenAt = Date(timeIntervalSince1970: seconds)
        }

        let featureColumns = ["sharpness", "exposure", "faces", "eyesClosed", "smiles",
                              "screenshot", "measures"]

        rows(db, "rating", ["assetID", "weight", "isRated", "judgements", "updatedAt"]
             + featureColumns) { row in
            let id = row.text("assetID") ?? ""
            payload.ratings.append(Rating(
                assetID: id,
                weight: row.double("weight"),
                isRated: row.int("isRated") != 0,
                judgements: row.int("judgements"),
                updatedAt: Date(timeIntervalSince1970: row.double("updatedAt"))
            ))
            // Do wersji 4 cechy jechały w tabeli ocen. Urządzenie jeszcze
            // niezaktualizowane dalej je wnosi.
            let legacy = Features(row: row, assetID: id)
            if legacy.carriesAnything { payload.features.append(legacy) }
        }

        rows(db, "feature", ["assetID"] + featureColumns) { row in
            let features = Features(row: row, assetID: row.text("assetID") ?? "")
            if features.carriesAnything { payload.features.append(features) }
        }

        rows(db, "print", ["assetID", "vector", "takenAt"]) { row in
            let vector = row.blob("vector")
            guard !vector.isEmpty else { return }
            payload.prints.append(Print(
                assetID: row.text("assetID") ?? "",
                vector: vector,
                takenAt: Date(timeIntervalSince1970: row.double("takenAt"))
            ))
        }

        rows(db, "verdict", ["key", "resolvedAt", "wasRejected", "championID", "challengerIndex"]) { row in
            payload.verdicts.append(Verdict(
                key: row.text("key") ?? "",
                resolvedAt: row.isNull("resolvedAt")
                    ? nil : Date(timeIntervalSince1970: row.double("resolvedAt")),
                wasRejected: row.int("wasRejected") != 0,
                championID: row.text("championID"),
                challengerIndex: row.int("challengerIndex")
            ))
        }
        return payload
    }

    // MARK: - Odczyt po nazwie kolumny

    /// Wiersz czytany **po nazwie**. Kolumna, której w pliku nie ma, daje
    /// wartość domyślną; kolumny, o które nie pytamy, po prostu nie istnieją
    /// dla czytnika. Na tym stoi zgodność w przód.
    fileprivate struct Row {
        let statement: OpaquePointer?
        let index: [String: Int32]

        func double(_ column: String) -> Double {
            index[column].map { sqlite3_column_double(statement, $0) } ?? 0
        }
        func int(_ column: String) -> Int {
            index[column].map { Int(sqlite3_column_int64(statement, $0)) } ?? 0
        }
        func text(_ column: String) -> String? {
            index[column].flatMap { SyncFile.text(statement, $0) }
        }
        func blob(_ column: String) -> Data {
            index[column].map { SyncFile.blob(statement, $0) } ?? Data()
        }
        func isNull(_ column: String) -> Bool {
            index[column].map { sqlite3_column_type(statement, $0) == SQLITE_NULL } ?? true
        }
    }

    /// Pyta tylko o kolumny, które plik faktycznie ma. Nazwy tabel i kolumn to
    /// stałe z kodu, nigdy dane z pliku.
    private static func rows(
        _ db: OpaquePointer?, _ table: String, _ wanted: [String], _ body: (Row) -> Void
    ) {
        var present = Set<String>()
        query(db, "PRAGMA table_info(\(table))") { statement in
            if let name = text(statement, 1) { present.insert(name) }
        }
        let used = wanted.filter(present.contains)
        guard !used.isEmpty else { return }

        let sql = "SELECT " + used.map { "\"\($0)\"" }.joined(separator: ", ") + " FROM \(table)"
        let index = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, Int32($0)) })
        query(db, sql) { body(Row(statement: $0, index: index)) }
    }

    // MARK: - Drobiazgi SQLite

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(
            statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
    }

    /// Jedna kompilacja zapytania, wiele wykonań. `sqlite3_reset` czyści stan
    /// po kroku, a powiązania i tak nadpisujemy przy następnym wierszu.
    private static func repeating<Row>(
        _ db: OpaquePointer?, _ sql: String, _ rows: [Row],
        _ bindRow: (OpaquePointer?, Row) -> Void
    ) {
        guard !rows.isEmpty else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        for row in rows {
            bindRow(statement, row)
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
    }

    private static func withStatement(
        _ db: OpaquePointer?, _ sql: String, _ body: (OpaquePointer?) -> Void
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        body(statement)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private static func query(
        _ db: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> Void
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        sqlite3_finalize(statement)
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    private static func insertMeta(_ db: OpaquePointer?, _ key: String, _ value: String) {
        withStatement(db, "INSERT OR REPLACE INTO meta VALUES(?,?)") { statement in
            bind(statement, 1, key)
            bind(statement, 2, value)
        }
    }

    private static func meta(_ db: OpaquePointer?, _ key: String) -> String? {
        var found: String?
        var statement: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        bind(statement, 1, key)
        if sqlite3_step(statement) == SQLITE_ROW { found = text(statement, 0) }
        sqlite3_finalize(statement)
        return found
    }
}

fileprivate extension SyncFile.Features {
    init(row: SyncFile.Row, assetID: String) {
        self.init(
            assetID: assetID,
            sharpness: row.double("sharpness"),
            exposure: row.double("exposure"),
            faces: row.int("faces"),
            eyesClosed: row.int("eyesClosed"),
            smiles: row.int("smiles"),
            isScreenshot: row.int("screenshot") != 0,
            measures: row.blob("measures")
        )
    }
}

enum SyncError: LocalizedError {
    case cannotWrite
    case noFolder

    var errorDescription: String? {
        switch self {
        case .cannotWrite: "Couldn't write the shared file."
        case .noFolder: "No shared folder chosen."
        }
    }
}
