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
    private static let ratingsKey = "native.ratings"
    private static let marksKey = "native.deletionAlbum"

    static func apply(_ snapshot: PhotoLibrary.NativeSnapshot, in context: ModelContext) {
        let defaults = UserDefaults.standard

        // Pierwszy odczyt gwiazdek to tylko punkt odniesienia. Bez wcześniejszego
        // stanu nie odróżnimy zmiany z zewnątrz od gwiazdki, która po prostu
        // jeszcze nie dogoniła nowszej wagi z pliku.
        let knownRatings = defaults.dictionary(forKey: ratingsKey) as? [String: Int]
        var lastRatings = knownRatings ?? [:]
        var ratingChanges: [String: Int] = [:]
        if knownRatings != nil {
            for (id, native) in snapshot.ratings where native != (lastRatings[id] ?? 0) {
                ratingChanges[id] = native
            }
        }

        // Album przy pierwszym odczycie liczy się w całości jako „dodane" —
        // oznaczenie jest odwracalne, a właśnie po to telefon ma je zobaczyć.
        let lastMarks = Set(defaults.stringArray(forKey: marksKey) ?? [])
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
        if lastRatings != knownRatings {
            defaults.set(lastRatings, forKey: ratingsKey)
        }
        if snapshot.deletionMarks != lastMarks {
            defaults.set(Array(snapshot.deletionMarks), forKey: marksKey)
        }
    }
}
