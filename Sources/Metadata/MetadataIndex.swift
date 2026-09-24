#if os(macOS)
import Foundation
import Photos
import SwiftData

/// Warstwa dla widoku: trzyma metadane bieżącego zdjęcia i pilnuje, żeby
/// szybkie przeskakiwanie strzałką nie zostawiło na ekranie opisu poprzedniego.
@MainActor
final class MetadataIndex: ObservableObject {
    @Published private(set) var current: AssetMetadata?
    @Published private(set) var failure: String?
    @Published private(set) var needsFullDiskAccess = false

    private let store = MetadataStore.shared

    func load(_ asset: PHAsset?) async {
        guard let asset else { current = nil; return }
        let identifier = asset.localIdentifier
        let loaded = await store.metadata(for: identifier)
        // Odczyt jest asynchroniczny, a zdjęcie mogło się w tym czasie zmienić.
        guard identifier == asset.localIdentifier else { return }
        current = loaded
        failure = await store.currentFailure()
        needsFullDiskAccess = await store.currentNeedsFullDiskAccess()
    }
}

/// Przepisuje cechy z baz systemu do naszego składu.
///
/// Jawna, jednorazowa operacja — tak samo jak liczenie odcisków i z tego samego
/// powodu: aplikacja nie ma prawa po cichu przemielić całego archiwum przy
/// pierwszym uruchomieniu. Wynik trafia do `Review`, więc stamtąd jedzie
/// synchronizacją na telefon, gdzie tych baz nie ma.
@MainActor
final class FeatureImport: ObservableObject {
    static let importedAtKey = "features.importedAt"

    @Published private(set) var isWorking = false
    @Published private(set) var summary: String?

    func run(context: ModelContext, library: PhotoLibrary) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let features = await MetadataStore.shared.features()
        let measures = await MetadataStore.shared.measures()
        guard !features.isEmpty || !measures.isEmpty else {
            summary = await MetadataStore.shared.currentFailure()
                ?? "The library database has no computed measures."
            return
        }

        // Rekord zakładamy **tylko** dla zdjęcia, które faktycznie coś niesie.
        // Inaczej powstałoby 26 tysięcy pustych ocen, z których każda jechałaby
        // potem w każdym pliku wymiany.
        let existing = Dictionary(
            ((try? context.fetch(FetchDescriptor<Review>())) ?? []).map { ($0.assetID, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        var touched = 0
        for asset in library.assets {
            let id = asset.localIdentifier
            let uuid = String(id.prefix(36))
            let found = features[uuid] ?? MetadataStore.Features()
            let packed = measures[uuid] ?? Data()
            guard found.sharpness > 0 || found.exposure > 0
                    || found.faces > 0 || found.isScreenshot || !packed.isEmpty else { continue }

            let review = existing[id] ?? {
                let fresh = Review(assetID: id)
                context.insert(fresh)
                return fresh
            }()

            // Bez `updatedAt`: to pomiar systemu, nie czyjaś decyzja.
            review.sharpness = found.sharpness
            review.exposure = found.exposure
            review.faces = found.faces
            review.eyesClosed = found.eyesClosed
            review.smiles = found.smiles
            review.isScreenshot = found.isScreenshot
            if !packed.isEmpty { review.measures = packed }
            touched += 1
        }

        try? context.save()
        // Znacznik dla synchronizacji: plik `-features` pisze tylko urządzenie,
        // które cechy policzyło samo — nie to, które je tylko dostało.
        UserDefaults.standard.set(Date.now, forKey: FeatureImport.importedAtKey)
        summary = "Loaded measures for \(touched) photos."
    }
}
#endif
