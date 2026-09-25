import Foundation
import SwiftData

/// Gwiazdki i album do skasowania czytane **z powrotem** z Photos.
///
/// **Photos wygrywa przy zmianie, nie przy każdej niezgodności.** Prostsza
/// reguła „gwiazdka w Photos zawsze ma rację" zniszczyłaby dane na dwa sposoby:
///
/// - Oceny sprzed `PHAsset.rating` (a przez długi czas tylko takie były) nie mają
///   gwiazdki w Photos. „Brak gwiazdki wygrywa" wyzerowałby całe archiwum ocen.
/// - iCloud Photos i folder wymiany przychodzą w różnym tempie. Nowsza waga
///   z drugiego urządzenia, przywieziona plikiem, przegrywałaby ze starą
///   gwiazdką, której Photos jeszcze nie zdążył zaktualizować.
///
/// Dlatego pamiętamy, co Photos pokazywał ostatnio, i działamy tylko na
/// różnicy: gwiazdka zmieniła się w Photos → waga idzie za nią; zdjęcie weszło
/// do albumu → oznaczone; wyszło → odznaczone. Brak zmiany → nic nie ruszamy.
@MainActor
enum NativeSync {
    static func apply(_ snapshot: PhotoLibrary.NativeSnapshot, in context: ModelContext) {
        let memory = NativeMemory.current

        // Pierwszy odczyt gwiazdek to tylko punkt odniesienia. Bez wcześniejszego
        // stanu nie odróżnimy zmiany z zewnątrz od gwiazdki, która po prostu
        // jeszcze nie dogoniła nowszej wagi z pliku.
        let knownRatings = memory.ratings
        var lastRatings = knownRatings ?? [:]
        var ratingChanges: [String: Int] = [:]
        if knownRatings != nil {
            for (id, native) in snapshot.ratings where native != (lastRatings[id] ?? 0) {
                ratingChanges[id] = native
            }
        }

        // Album przy pierwszym odczycie liczy się w całości jako „dodane" —
        // oznaczenie jest odwracalne, a właśnie po to telefon ma je zobaczyć.
        let lastMarks = memory.marks
        let added = snapshot.deletionMarks.subtracting(lastMarks)
        let removed = lastMarks.subtracting(snapshot.deletionMarks)

        let touched = Array(Set(ratingChanges.keys).union(added).union(removed))
        if !touched.isEmpty {
            let found = (try? context.fetch(FetchDescriptor<Review>(
                predicate: #Predicate { touched.contains($0.assetID) }
            ))) ?? []
            var byID = Dictionary(found.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })

            func review(_ id: String) -> Review {
                if let existing = byID[id] { return existing }
                let fresh = Review(assetID: id)
                // Rekord założony z odczytu nie jest świeżą decyzją. Z datą
                // „teraz" wygrałby przy scalaniu z każdą oceną z drugiego
                // urządzenia, także dokładniejszą.
                fresh.updatedAt = .distantPast
                context.insert(fresh)
                byID[id] = fresh
                return fresh
            }

            for (id, native) in ratingChanges {
                if native > 0 {
                    review(id).adoptNativeStars(native)
                } else {
                    byID[id]?.adoptNativeStars(0)
                }
            }
            for id in added where byID[id]?.markedForDeletion != true {
                review(id).markedForDeletion = true
            }
            for id in removed {
                byID[id]?.markedForDeletion = false
            }
            try? context.save()
        }

        if snapshot.isFull {
            // Zdjęcia pominięte w tym odczycie (zapis w drodze) zachowują
            // poprzednią wartość.
            lastRatings = lastRatings.filter { snapshot.ratings[$0.key] == nil }
        }
        for (id, native) in snapshot.ratings {
            lastRatings[id] = native > 0 ? native : nil
        }
        if lastRatings != knownRatings || snapshot.deletionMarks != lastMarks {
            NativeMemory.remember(ratings: lastRatings, marks: snapshot.deletionMarks)
        }
    }
}

/// Co Photos pokazywał ostatnio — w pliku, nie w `UserDefaults`.
///
/// W `UserDefaults` każda ocena zapisywała słownik gwiazdek **całej**
/// biblioteki (25 tysięcy wpisów), a SwiftUI przy każdym zapisie do
/// `UserDefaults` budzi wszystkie widoki z `@AppStorage` — widok główny
/// razem z nimi, czyli całe okno. Tu stan żyje w pamięci, a na dysk idzie
/// dwie sekundy po ostatniej zmianie, w tle.
@MainActor
enum NativeMemory {
    struct State: Codable, Equatable {
        /// `nil` — jeszcze nigdy nie odczytany: pierwszy odczyt to tylko
        /// punkt odniesienia (patrz `NativeSync`).
        var ratings: [String: Int]?
        var marks: Set<String> = []
    }

    private static var state: State?
    private static var pendingWrite: DispatchWorkItem?

    static var current: State {
        if let state { return state }
        if let stored = read() {
            state = stored
            return stored
        }
        let migrated = migrateFromDefaults()
        state = migrated
        if migrated != State() { scheduleWrite(migrated) }
        return migrated
    }

    static func remember(ratings: [String: Int], marks: Set<String>) {
        let next = State(ratings: ratings, marks: marks)
        guard next != current else { return }
        state = next
        scheduleWrite(next)
    }

    private static func scheduleWrite(_ next: State) {
        pendingWrite?.cancel()
        let work = DispatchWorkItem {
            guard let data = try? PropertyListEncoder().encode(next) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        pendingWrite = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    private nonisolated static var url: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "lightbrary")
            .appending(path: "native-state.plist")
    }

    private static func read() -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(State.self, from: data)
    }

    /// Jednorazowo: stan zapisany przez wcześniejsze wersje w `UserDefaults`.
    /// Bez tego pierwsze uruchomienie po aktualizacji wzięłoby się za pierwsze
    /// w ogóle i przegapiło gwiazdki zmienione w Photos w międzyczasie.
    private static func migrateFromDefaults() -> State {
        let defaults = UserDefaults.standard
        let migrated = State(
            ratings: defaults.dictionary(forKey: "native.ratings") as? [String: Int],
            marks: Set(defaults.stringArray(forKey: "native.deletionAlbum") ?? [])
        )
        defaults.removeObject(forKey: "native.ratings")
        defaults.removeObject(forKey: "native.deletionAlbum")
        return migrated
    }
}
