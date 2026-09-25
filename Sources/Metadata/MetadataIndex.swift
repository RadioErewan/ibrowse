#if os(macOS)
import Foundation
import Photos
import SwiftData

/// Warstwa dla widoku: trzyma metadane bieżącego zdjęcia i pilnuje, żeby
/// szybkie przeskakiwanie strzałką nie zostawiło na ekranie opisu poprzedniego.
///
/// **Bez baz Photos** (krok 5 w DECYZJE.md). Sekcje panelu i technikę przywozi
/// eksporter w pliku cech (`Review.panel`, schemat 6). Gdy o zdjęciu nic nie
/// przywiózł: technika z oryginału przez ImageIO — **tylko gdy leży na dysku**,
/// niczego nie pobieramy — i nazwa miejsca z geokodowania współrzędnych.
@MainActor
final class MetadataIndex: ObservableObject {
    @Published private(set) var current: AssetMetadata?
    /// Uwaga pod panelem, gdy części danych nie ma skąd wziąć.
    @Published private(set) var note: String?

    private var loading: String?

    func load(_ asset: PHAsset?, context: ModelContext) async {
        guard let asset else { current = nil; note = nil; return }
        let identifier = asset.localIdentifier
        loading = identifier

        var result = Self.exported(for: identifier, in: context) ?? AssetMetadata()
        let fromExporter = result != AssetMetadata()
        result.filename = AssetFacts.quick(for: asset).filename
        current = result
        note = fromExporter ? nil
            : "Places, people and scenes come from Lightbrary Exporter on the Mac that holds your library."

        guard !fromExporter else { return }
        // Zapas bez eksportera. Odczyt oryginału i geokodowanie są wolne,
        // a zdjęcie mogło się w tym czasie zmienić — stąd `loading`.
        let facts = await AssetFacts.detailed(for: asset)
        guard loading == identifier else { return }
        result.camera = facts.camera
        result.lens = facts.lens
        result.iso = facts.iso
        result.aperture = facts.aperture
        result.shutter = facts.shutter
        result.focalLength = facts.focalLength
        current = result

        if let place = await AssetFacts.place(for: asset), loading == identifier {
            result.place = [place]
            current = result
        }
    }

    /// Na życzenie: pobiera oryginał z iCloud i czyta z niego technikę.
    func loadOriginal(_ asset: PHAsset) async {
        let identifier = asset.localIdentifier
        loading = identifier
        let facts = await AssetFacts.detailed(for: asset, allowNetwork: true)
        guard loading == identifier, var result = current else { return }
        result.camera = facts.camera
        result.lens = facts.lens
        result.iso = facts.iso
        result.aperture = facts.aperture
        result.shutter = facts.shutter
        result.focalLength = facts.focalLength
        current = result
    }

    private static func exported(for identifier: String, in context: ModelContext) -> AssetMetadata? {
        let descriptor = FetchDescriptor<Review>(predicate: #Predicate { $0.assetID == identifier })
        guard let panel = (try? context.fetch(descriptor))?.first?.panel else { return nil }
        return AssetMetadata(json: panel)
    }
}
#endif
