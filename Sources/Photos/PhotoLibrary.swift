import Photos
import SwiftUI

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

/// Dostęp do biblioteki przez PhotoKit, a nie przez czytanie Photos.sqlite.
///
/// Baza jest szybsza i pokazuje więcej (etykiety Apple, OCR), ale istnieje
/// wyłącznie na macOS i jej schemat zmienia się z każdym wydaniem systemu.
/// PhotoKit działa identycznie na macOS i iOS, sam dociąga oryginały z iCloud
/// i nie wymaga pełnego dostępu do dysku.
@MainActor
final class PhotoLibrary: ObservableObject {
    @Published private(set) var authorization: PHAuthorizationStatus = .notDetermined
    @Published private(set) var assets: [PHAsset] = []

    /// Lata, w których cokolwiek jest, wraz z liczbą zdjęć.
    ///
    /// Sam warunek zawężania mieszka w `Filters` — biblioteka tylko dostarcza
    /// materiał. Odciski liczymy zawsze dla całości, żeby serie nie urywały
    /// się na granicy zakresu.
    @Published private(set) var years: [(year: Int, count: Int)] = []

    /// Skorowidz po `localIdentifier`. Bez niego każde wyszukanie assetu to
    /// liniowy przelot przez 25 tysięcy pozycji — przy widoku, który odświeża
    /// się kilka razy na klatkę, to zabija responsywność.
    private(set) var byID: [String: PHAsset] = [:]

    private let imageManager = PHCachingImageManager()

    func asset(id: String) -> PHAsset? { byID[id] }

    func start() async {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .authorized || authorization == .limited {
            loadAssets()
        }
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if authorization == .authorized || authorization == .limited {
            loadAssets()
        }
    }

    private func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue
        )

        let result = PHAsset.fetchAssets(with: options)
        var collected: [PHAsset] = []
        collected.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in collected.append(asset) }
        assets = collected
        byID = Dictionary(collected.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })

        let calendar = Calendar.current
        var tally: [Int: Int] = [:]
        for asset in collected {
            guard let date = asset.creationDate else { continue }
            tally[calendar.component(.year, from: date), default: 0] += 1
        }
        years = tally.map { (year: $0.key, count: $0.value) }.sorted { $0.year < $1.year }
    }

    /// Najlepszy wariant dostępny **bez sieci**, oddany natychmiast.
    ///
    /// Bez tego kroku widok skacze od miniatury 64×37 prosto do 2048 px,
    /// a między nimi stoi kilka sekund pobierania oryginału z iCloud.
    /// Tu dostajesz od razu to, co leży na dysku — u Radka 360 px dla całej
    /// biblioteki albo 1280 px dla połowy.
    @discardableResult
    func localImage(
        for asset: PHAsset,
        targetSize: CGSize,
        onLoad: @escaping (PlatformImage?) -> Void
    ) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        return imageManager.requestImage(
            for: asset, targetSize: targetSize,
            contentMode: .aspectFit, options: options
        ) { image, _ in onLoad(image) }
    }

    /// Wczytuje obraz w rozmiarze dopasowanym do ekranu.
    ///
    /// `isNetworkAccessAllowed` jest tu kluczowe: przy włączonym „Optymalizuj
    /// pamięć Maca" większość oryginałów jest tylko w iCloud, a PhotoKit sam
    /// je dociąga. `opportunistic` daje najpierw miniaturę, potem pełną wersję,
    /// więc widok nigdy nie stoi pusty.
    func image(
        for asset: PHAsset,
        targetSize: CGSize,
        onUpdate: @escaping (PlatformImage?, Bool) -> Void
    ) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact

        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            onUpdate(image, degraded)
        }
    }

    /// Miniatura do siatki, ładowana progresywnie.
    ///
    /// `opportunistic` woła handler dwa razy: najpierw z tym, co jest w cache
    /// (kafelek pojawia się natychmiast, bywa rozmyty), potem z wersją w pełnej
    /// żądanej rozdzielczości. `fastFormat` dawałby tylko ten pierwszy krok,
    /// czyli trwałą pikselozę.
    ///
    /// Sieć jest wyłączona świadomie: przewijanie archiwum nie ma prawa
    /// generować ruchu do iCloud. Pełne wersje dociągamy dopiero w widoku
    /// pojedynczego zdjęcia, gdzie użytkownik faktycznie na nie patrzy.
    func thumbnail(
        for asset: PHAsset,
        side: Double,
        onUpdate: @escaping (PlatformImage?, Bool) -> Void
    ) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact

        return imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            onUpdate(image, degraded)
        }
    }

    /// Oryginał w pełnej rozdzielczości — wyłącznie do oceny ostrości.
    ///
    /// Świadomie osobno od `image(for:)`, bo koszt jest zupełnie inny:
    /// rozkodowanie 50 Mpx to setki megabajtów pamięci, a na iOS pobranie
    /// oryginału z iCloud zostawia go na urządzeniu **na stałe**. Dlatego
    /// telefon dostaje wyłącznie to, co już leży lokalnie, a decyzję
    /// o pobraniu podejmuje wywołujący, nie ta metoda.
    ///
    /// Na Macu przyrost jest ograniczony z góry przez systemową politykę
    /// „Optymalizuj pamięć": to pamięć podręczna zarządzana przez system,
    /// nie studnia bez dna.
    @discardableResult
    func original(
        for asset: PHAsset,
        allowNetwork: Bool,
        onLoad: @escaping (PlatformImage?) -> Void
    ) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none

        return imageManager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !degraded else { return }
            onLoad(image)
        }
    }

    func cancel(_ request: PHImageRequestID) {
        imageManager.cancelImageRequest(request)
    }

    /// Podgrzewa cache dla sąsiadów bieżącego zdjęcia, żeby przejście
    /// klawiszem albo gestem było natychmiastowe.
    ///
    /// Na telefonie **bez sieci**, i to jest decyzja o miejscu na dysku, nie
    /// o szybkości. Każde pobranie oryginału z iCloud zostaje na urządzeniu,
    /// a PhotoKit nie daje żadnego sposobu, żeby je potem usunąć — kasowanie
    /// lokalnych kopii robi wyłącznie system, pod polityką „Optymalizuj pamięć".
    /// Pobieranie na zapas czterech zdjęć do przodu zamieniłoby więc telefon
    /// w kopię całej biblioteki. Na Macu miejsca jest więcej i wybieramy tempo.
    func prefetch(_ assets: [PHAsset], targetSize: CGSize) {
        let options = PHImageRequestOptions()
        #if os(iOS)
        options.isNetworkAccessAllowed = false
        #else
        options.isNetworkAccessAllowed = true
        #endif
        options.deliveryMode = .opportunistic
        imageManager.startCachingImages(
            for: assets, targetSize: targetSize,
            contentMode: .aspectFit, options: options
        )
    }

    /// Zwalnia renditiony trzymane przez menedżera. To cache aplikacji, nie
    /// biblioteki systemowej — oryginałów ściągniętych do Zdjęć nie usuwa.
    func releaseCache() {
        imageManager.stopCachingImagesForAllAssets()
    }

    /// Usuwa zdjęcia z biblioteki. System pokazuje własne potwierdzenie,
    /// a skasowane trafiają do „Ostatnio usunięte" na 30 dni — aplikacja
    /// celowo nie próbuje tego obchodzić.
    func delete(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        loadAssets()
    }
}
