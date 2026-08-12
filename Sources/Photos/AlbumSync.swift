import Photos
import SwiftData
import SwiftUI

/// Przenosi oceny między urządzeniami przez albumy Apple Photos.
///
/// Naturalnym nośnikiem byłyby słowa kluczowe, ale **PhotoKit ich nie zna** —
/// `PHAsset` nie ma takiej właściwości ani do odczytu, ani do zapisu. Na macOS
/// dałoby się je ustawić przez AppleScript, na iOS nie ma odpowiednika, więc
/// synchronizacja byłaby jednokierunkowa.
///
/// Albumy PhotoKit obsługuje w całości na obu platformach, a iCloud synchronizuje
/// je bez opłat — w przeciwieństwie do CloudKit, który wymaga płatnego konta
/// dewelopera. Przy okazji oceny stają się widoczne w natywnej aplikacji Zdjęcia.
///
/// Świadomy kompromis: nośnikiem jest **gwiazdka, nie pełna waga**. Pięć albumów
/// zamiast dwudziestu utrzymuje bibliotekę w czytelnym stanie, a dokładna waga
/// i tak zostaje lokalnie. Między urządzeniami wędruje zaokrąglenie.
@MainActor
final class AlbumSync: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSummary: String?

    private let prefix = "ibrowse ★"

    private func title(forStars stars: Int) -> String { "\(prefix)\(stars)" }

    // MARK: - Odczyt

    /// Zasiewa oceny, których to urządzenie jeszcze nie zna.
    ///
    /// Celowo **nie nadpisuje** istniejących ocen: nie znamy czasu oceny na
    /// drugim urządzeniu, więc każda próba rozstrzygania konfliktów byłaby
    /// zgadywaniem. Album uzupełnia luki, nigdy nie kasuje twojej pracy.
    func pull(into context: ModelContext) -> Int {
        let known = Set(
            ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
                .filter(\.isRated).map(\.assetID)
        )
        var seeded = 0

        for stars in 1...5 {
            guard let album = findAlbum(titled: title(forStars: stars)) else { continue }
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            assets.enumerateObjects { asset, _, _ in
                guard !known.contains(asset.localIdentifier) else { return }
                Review.upsert(assetID: asset.localIdentifier, in: context) {
                    $0.set(Double(stars))
                }
                seeded += 1
            }
        }
        return seeded
    }

    // MARK: - Zapis

    /// Zapisuje oceny do albumów jedną transakcją na album.
    ///
    /// Wsadowo, a nie po każdym geście: zapis przez PhotoKit jest o rzędy
    /// wielkości wolniejszy od SwiftData i wywołanie go przy każdym swipie
    /// zabiłoby tempo oceniania.
    func push(from context: ModelContext) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let rated = ((try? context.fetch(FetchDescriptor<Review>())) ?? [])
            .filter { $0.isRated && $0.stars >= 1 }

        var byStars: [Int: [String]] = [:]
        for review in rated { byStars[review.stars, default: []].append(review.assetID) }

        var written = 0
        for stars in 1...5 {
            let wanted = byStars[stars] ?? []
            do {
                try await write(stars: stars, assetIDs: wanted)
                written += wanted.count
            } catch {
                lastSummary = "Nie udało się zapisać albumu ★\(stars): \(error.localizedDescription)"
                return
            }
        }
        lastSummary = "Zapisano \(written) ocen do albumów"
    }

    /// Doprowadza album do stanu docelowego: dokłada brakujące, usuwa te,
    /// których ocena się zmieniła. Bez odejmowania zdjęcie awansowane z ★3 na
    /// ★4 zostałoby w obu albumach naraz.
    private func write(stars: Int, assetIDs: [String]) async throws {
        let name = title(forStars: stars)
        let existing = findAlbum(titled: name)

        if existing == nil && assetIDs.isEmpty { return }

        let wanted = Set(assetIDs)
        var present = Set<String>()
        if let existing {
            PHAsset.fetchAssets(in: existing, options: nil)
                .enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        }

        let toAdd = wanted.subtracting(present)
        let toRemove = present.subtracting(wanted)
        if existing != nil && toAdd.isEmpty && toRemove.isEmpty { return }

        try await PHPhotoLibrary.shared().performChanges {
            let request: PHAssetCollectionChangeRequest?
            if let existing {
                request = PHAssetCollectionChangeRequest(for: existing)
            } else {
                request = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: name)
            }
            guard let request else { return }

            if !toAdd.isEmpty {
                let assets = PHAsset.fetchAssets(
                    withLocalIdentifiers: Array(toAdd), options: nil
                )
                request.addAssets(assets)
            }
            if !toRemove.isEmpty, existing != nil {
                let assets = PHAsset.fetchAssets(
                    withLocalIdentifiers: Array(toRemove), options: nil
                )
                request.removeAssets(assets)
            }
        }
    }

    private func findAlbum(titled name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", name)
        return PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options
        ).firstObject
    }
}
