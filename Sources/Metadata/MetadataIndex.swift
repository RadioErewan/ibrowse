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
#endif
