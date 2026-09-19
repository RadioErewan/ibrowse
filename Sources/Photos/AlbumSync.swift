import Photos
import SwiftData
import SwiftUI

/// Odczytuje oceny zostawione w albumach z czasu, zanim `PHAsset.rating`
/// istniało.
///
/// **Historyczny mechanizm, już tylko do odczytu.** Do macOS 27 / iOS 27
/// PhotoKit nie znał ocen w ogóle — `PHAsset` nie miał takiej właściwości ani
/// do odczytu, ani do zapisu. Album był obejściem: pięć sztucznych albumów
/// („lightbrary ★1"…„★5"), które iCloud synchronizuje za darmo, żeby przemycić
/// choć zaokrągloną gwiazdkę między urządzeniami.
///
/// Teraz robi to `PhotoLibrary.setRating` — jedno natywne pole, bez pośrednika
/// i bez bałaganu w cudzej bibliotece. Ten typ zostaje wyłącznie jako
/// jednorazowa siatka bezpieczeństwa: gdyby na którymś urządzeniu zalegały
/// jeszcze stare albumy z poprzedniej wersji, `pull` wciągnie je do składu
/// tak samo jak dawniej. Nic już do nich nie pisze.
@MainActor
final class AlbumSync: ObservableObject {
    private let prefix = "lightbrary ★"

    private func title(forStars stars: Int) -> String { "\(prefix)\(stars)" }

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

    private func findAlbum(titled name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", name)
        return PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options
        ).firstObject
    }
}
