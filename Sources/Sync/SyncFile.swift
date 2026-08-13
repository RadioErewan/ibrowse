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
/// urządzenia widzą tę samą bibliotekę iCloud i posługują się tymi samymi
/// `localIdentifier`. Bez tego nie ma czego dopasowywać.
struct SyncFile {

    /// Wersja formatu. Gdy się zmieni, starsze pliki są pomijane przy czytaniu
    /// zamiast wczytywane błędnie — cudzy plik z przyszłości to jedyny scenariusz,
    /// w którym cicha porażka byłaby gorsza od głośnej.
    static let schema = 1
    static let fileExtension = "ibsync"

    // MARK: - Przenoszone dane

    struct Rating: Sendable {
        var assetID: String
        var weight: Double
        var isRated: Bool
        var judgements: Int
        var markedForDeletion: Bool
        var updatedAt: Date
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
                                judgements INT, marked INT, updatedAt REAL);
            CREATE TABLE print(assetID TEXT PRIMARY KEY, vector BLOB, takenAt REAL);
            CREATE TABLE verdict(key TEXT PRIMARY KEY, resolvedAt REAL, wasRejected INT,
                                 championID TEXT, challengerIndex INT);
            """)

        exec(db, "BEGIN")
        insertMeta(db, "schema", String(schema))
        insertMeta(db, "writtenAt", String(payload.writtenAt.timeIntervalSince1970))
        insertMeta(db, "device", payload.deviceName)

        // Zapytanie kompilujemy **raz na tabelę**, nie raz na wiersz.
        // Pierwsza wersja przygotowywała je w pętli i zapis 25 tysięcy
        // odcisków trwał pół minuty — to nie dysk był wąskim gardłem, tylko
        // dwadzieścia pięć tysięcy kompilacji tego samego SQL-a.
        repeating(db, "INSERT OR REPLACE INTO rating VALUES(?,?,?,?,?,?)", payload.ratings) {
            statement, rating in
            bind(statement, 1, rating.assetID)
            sqlite3_bind_double(statement, 2, rating.weight)
            sqlite3_bind_int(statement, 3, rating.isRated ? 1 : 0)
            sqlite3_bind_int(statement, 4, Int32(rating.judgements))
            sqlite3_bind_int(statement, 5, rating.markedForDeletion ? 1 : 0)
            sqlite3_bind_double(statement, 6, rating.updatedAt.timeIntervalSince1970)
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

    static func read(_ url: URL) -> Payload? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        guard let version = meta(db, "schema"), Int(version) == schema else { return nil }

        var payload = Payload()
        payload.deviceName = meta(db, "device") ?? "?"
        if let written = meta(db, "writtenAt"), let seconds = Double(written) {
            payload.writtenAt = Date(timeIntervalSince1970: seconds)
        }

        query(db, "SELECT assetID, weight, isRated, judgements, marked, updatedAt FROM rating") {
            payload.ratings.append(Rating(
                assetID: text($0, 0) ?? "",
                weight: sqlite3_column_double($0, 1),
                isRated: sqlite3_column_int($0, 2) != 0,
                judgements: Int(sqlite3_column_int($0, 3)),
                markedForDeletion: sqlite3_column_int($0, 4) != 0,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double($0, 5))
            ))
        }

        query(db, "SELECT assetID, vector, takenAt FROM print") { statement in
            guard let bytes = sqlite3_column_blob(statement, 1) else { return }
            let count = Int(sqlite3_column_bytes(statement, 1))
            payload.prints.append(Print(
                assetID: text(statement, 0) ?? "",
                vector: Data(bytes: bytes, count: count),
                takenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }

        query(db, "SELECT key, resolvedAt, wasRejected, championID, challengerIndex FROM verdict") {
            payload.verdicts.append(Verdict(
                key: text($0, 0) ?? "",
                resolvedAt: sqlite3_column_type($0, 1) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double($0, 1)),
                wasRejected: sqlite3_column_int($0, 2) != 0,
                championID: text($0, 3),
                challengerIndex: Int(sqlite3_column_int($0, 4))
            ))
        }
        return payload
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

enum SyncError: LocalizedError {
    case cannotWrite
    case noFolder

    var errorDescription: String? {
        switch self {
        case .cannotWrite: "Nie udało się zapisać pliku wymiany."
        case .noFolder: "Nie wskazano folderu wymiany."
        }
    }
}
