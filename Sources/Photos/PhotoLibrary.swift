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
            await Self.nextRunLoopTurn()
            await loadAssets()
        }
    }

    /// Zgoda przychodzi, a zaraz po niej — bez żadnego oddechu — `loadAssets()`
    /// zapełnia `assets`. Dwie zmiany `@Published` jedna po drugiej, bez
    /// zawieszenia między nimi, SwiftUI zlepia w jedną aktualizację: widok
    /// uprawnień znika, a w jego miejsce wchodzi od razu pełna przestrzeń
    /// robocza — cała siatka, panel filtrów, trzy kolumny na raz.
    ///
    /// Dwa różne crashe z dwóch różnych Maców (ten sam wyjątek AppKit,
    /// `_postWindowNeedsUpdateConstraints` w trakcie już trwającego
    /// `layoutIfNeeded`, ale za każdym razem inny wewnętrzny tor: raz przez
    /// `@FocusState`, raz przez `NSHostingView.invalidateSafeAreaInsets()`)
    /// wskazują, że problemem nie jest jedna linia w jednym widoku, tylko sam
    /// moment tej podmiany — zachodzi ona w tej samej kontynuacji, w której
    /// dopiero co domknęło się systemowe okno zgody, więc AppKit może wciąż
    /// kończyć własną transakcję układu wywołaną jego zamknięciem.
    ///
    /// `nextRunLoopTurn()` wstawia tu prawdziwą, gwarantowaną przez GCD
    /// granicę obiegu pętli zdarzeń — patrz ten sam wzorzec w `GridView`,
    /// `CullView` i `PairView`, gdzie zawiódł odpowiednik przez `Task`.
    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if authorization == .authorized || authorization == .limited {
            await Self.nextRunLoopTurn()
            await loadAssets()
        }
    }

    private static func nextRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Zmiany w bibliotece

    /// Bez tego lista zdjęć była migawką z chwili startu: zdjęcia dodane lub
    /// skasowane na innym urządzeniu i przywiezione przez iCloud pojawiały się
    /// dopiero po ponownym uruchomieniu.
    private var fetchResult: PHFetchResult<PHAsset>?
    private var observer: ChangeObserver?
    private var pendingReload: Task<Void, Never>?

    private func observeChanges() {
        guard observer == nil else { return }
        let observer = ChangeObserver { [weak self] change in
            // `DispatchQueue.main.async`, nie `Task`: kolejność ma znaczenie,
            // bo każde powiadomienie liczy się względem poprzedniego wyniku.
            DispatchQueue.main.async { self?.libraryDidChange(change) }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    /// Przeładowanie listy **tylko przy zmianie zestawu** zdjęć. Własne zapisy
    /// aplikacji — gwiazdka, album do skasowania — też przychodzą tu jako
    /// zmiana, i przy każdym `X` przeładowanie 25 tysięcy zdjęć zabiłoby tempo
    /// oceniania. Zmiana treści (`changedObjects`, np. gwiazdka) i albumu idzie
    /// tylko do odczytu stanu natywnego, bez przebudowy listy.
    private func libraryDidChange(_ change: PHChange) {
        var changed: [PHAsset] = []
        if let current = fetchResult, let details = change.changeDetails(for: current) {
            fetchResult = details.fetchResultAfterChanges

            let setChanged = !details.hasIncrementalChanges
                || (details.insertedIndexes?.count ?? 0) > 0
                || (details.removedIndexes?.count ?? 0) > 0
            if setChanged {
                // Synchronizacja przywozi zmiany seriami — jedno przeładowanie
                // po ustaniu, nie po każdej. Przebudowa sama odczyta stan natywny.
                pendingReload?.cancel()
                pendingReload = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let result = fetchResult else { return }
                    await rebuild(from: result)
                }
                return
            }
            changed = details.changedObjects
        }
        // Także bez zmian w zdjęciach: dodanie do albumu nie zmienia samego
        // zdjęcia, a to właśnie oznaczenie do skasowania.
        //
        // **Paczkami.** Każdy nasz zapis wraca jako osobne powiadomienie; przy
        // szybkim ocenianiu albo zmianie całej grupy szły ich dziesiątki
        // i każde osobno czytało album, zapisywało bazę i budziło widoki.
        // Zbieramy je przez chwilę i odczytujemy stan raz — ostatnia wersja
        // każdego zdjęcia wygrywa.
        for asset in changed { pendingNative[asset.localIdentifier] = asset }
        pendingNativeFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in self?.flushNative() }
        pendingNativeFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: flush)
    }

    private var pendingNative: [String: PHAsset] = [:]
    private var pendingNativeFlush: DispatchWorkItem?

    private func flushNative() {
        let batch = Array(pendingNative.values)
        pendingNative.removeAll()
        pendingNativeFlush = nil
        emitNative(from: batch, isFull: false)
    }

    /// Ręczne odświeżenie obok obserwatora — na wypadek, gdyby powiadomienie
    /// nie przyszło. Nie przyspiesza synchronizacji iCloud: pobiera tylko to,
    /// co PhotoKit już ma lokalnie.
    func reload() {
        guard authorization == .authorized || authorization == .limited else { return }
        pendingReload?.cancel()
        Task { await loadAssets() }
    }

    /// Pobranie i przejście przez całą bibliotekę trwa na dużej bibliotece
    /// półtorej sekundy — na głównym wątku to było zamrożone okno przy
    /// starcie. `PHFetchResult` i `PHAsset` są niezmienne i bezpieczne między
    /// wątkami, więc liczymy w tle, a tu tylko podmieniamy wynik.
    private func loadAssets() async {
        let result = await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = NSPredicate(
                format: "mediaType == %d", PHAssetMediaType.image.rawValue
            )
            return Trace.measure("photos.fetch") { PHAsset.fetchAssets(with: options) }
        }.value
        fetchResult = result
        observeChanges()
        await rebuild(from: result)
    }

    private struct Collected: @unchecked Sendable {
        var assets: [PHAsset]
        var byID: [String: PHAsset]
        var years: [(year: Int, count: Int)]
    }

    /// Kolejna przebudowa, która przyszła w trakcie poprzedniej, wygrywa.
    private var rebuildGeneration = 0

    private func rebuild(from result: PHFetchResult<PHAsset>) async {
        rebuildGeneration += 1
        let mine = rebuildGeneration
        let box = UncheckedBox(result)
        let collected = await Task.detached(priority: .userInitiated) {
            Trace.measure("photos.enumerate") { Self.collect(box.value) }
        }.value
        guard mine == rebuildGeneration else { return }

        assets = collected.assets
        byID = collected.byID
        years = collected.years
        // Pełny odczyt poniżej obejmuje wszystko, co czekało w paczce.
        pendingNativeFlush?.cancel()
        pendingNative.removeAll()
        Trace.measure("photos.native") { emitNative(from: collected.assets, isFull: true) }
    }

    nonisolated private static func collect(_ result: PHFetchResult<PHAsset>) -> Collected {
        var collected: [PHAsset] = []
        collected.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in collected.append(asset) }
        let byID = Dictionary(collected.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })

        let calendar = Calendar.current
        var tally: [Int: Int] = [:]
        for asset in collected {
            guard let date = asset.creationDate else { continue }
            tally[calendar.component(.year, from: date), default: 0] += 1
        }
        let years = tally.map { (year: $0.key, count: $0.value) }.sorted { $0.year < $1.year }
        return Collected(assets: collected, byID: byID, years: years)
    }

    // MARK: - Stan natywny: gwiazdki i album do skasowania

    /// To, co Photos wie o decyzjach: gwiazdka i obecność w albumie do
    /// skasowania. Stosuje go `NativeSync` — biblioteka nie ma dostępu do bazy
    /// ocen, więc tylko podaje dalej.
    struct NativeSnapshot {
        /// Gwiazdki zbadanych zdjęć (0 = brak). Przy `isFull` — całej biblioteki.
        var ratings: [String: Int]
        var isFull: Bool
        var deletionMarks: Set<String>
    }

    var onNativeSnapshot: ((NativeSnapshot) -> Void)?

    /// Własne zapisy w drodze. Szybkie „4, potem 5" daje dwa powiadomienia,
    /// i pierwsze — z gwiazdką 4 — przyszłoby, gdy ocena już wynosi 5. Bez tego
    /// odczyt uznałby je za zmianę z zewnątrz i cofnął ocenę. Dopóki Photos
    /// nie pokaże tego, co zapisaliśmy, zdjęcie jest pomijane.
    private var intendedRatings: [String: Int] = [:]
    private var intendedMarks: [String: Bool] = [:]

    private func emitNative(from assets: [PHAsset], isFull: Bool) {
        guard let onNativeSnapshot else { return }
        var ratings: [String: Int] = [:]
        for asset in assets {
            let id = asset.localIdentifier
            let native = asset.rating.rawValue
            if let intended = intendedRatings[id] {
                guard intended == native else { continue }
                intendedRatings[id] = nil
            }
            ratings[id] = native
        }

        var marks = Trace.measure("photos.album") { Self.deletionAlbumMembers() }
        for (id, intended) in intendedMarks {
            if marks.contains(id) == intended {
                intendedMarks[id] = nil
            } else if intended {
                marks.insert(id)
            } else {
                marks.remove(id)
            }
        }
        Trace.measure("native.apply") {
            onNativeSnapshot(NativeSnapshot(ratings: ratings, isFull: isFull, deletionMarks: marks))
        }
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
    /// Ile zdjęć faktycznie zniknie przy skasowaniu tego jednego.
    ///
    /// Biblioteka wczytuje serie z aparatu tak, jak PhotoKit robi to domyślnie:
    /// jako **jedno** zdjęcie, reprezentanta. A skasowanie reprezentanta kasuje
    /// całą serię — system pytał „Delete 10 photos from this burst?" przy puli,
    /// którą aplikacja opisywała jako jedno zdjęcie.
    func deletionSize(of asset: PHAsset) -> Int {
        guard asset.representsBurst, let burst = asset.burstIdentifier else { return 1 }
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        return max(PHAsset.fetchAssets(withBurstIdentifier: burst, options: options).count, 1)
    }

    func delete(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        await loadAssets()
    }

    /// Prawdziwa, zapisywalna, natywnie synchronizowana gwiazdka —
    /// `PHAssetChangeRequest.rating`, dostępna od macOS 27 / iOS 27.
    ///
    /// **Zastępuje `AlbumSync`**, nie uzupełnia go. Album był obejściem na
    /// czas, gdy PhotoKit nie znał ocen — pięć sztucznych albumów w cudzej
    /// bibliotece, żeby przemycić to, co teraz jest jednym polem. Ten sam
    /// efekt (gwiazdka widoczna w natywnych Zdjęciach, zsynchronizowana przez
    /// iCloud), bez bałaganu i bez pośrednika.
    ///
    /// `0` i „nieustawiona" są tym samym po stronie Apple — `PHAssetRating`
    /// ma `unset = 0`, więc zero gwiazdek i brak oceny to jedna wartość
    /// w typie systemu. To nie jest nasza strata: nasz `stars == 0` przy
    /// `isRated == true` („wyzerowana ocena", odróżniona od „nietknięta")
    /// zostaje wewnętrznym rozróżnieniem — na zewnątrz i tak nie da się go
    /// wyrazić inaczej niż brakiem gwiazdek.
    ///
    /// **Synchroniczne z założenia.** Zamiar zapisu musi być znany w tej samej
    /// chwili, w której zmienia się ocena w bazie. Wersja wołana przez `Task`
    /// rejestrowała go chwilę później, a w tę lukę wpadało powiadomienie
    /// o poprzednim zapisie: przy szybkim `-` z 3,25 gwiazdka 4 wracała jako
    /// „zmiana z zewnątrz" i podbijała wagę do 4,0.
    func setRating(_ stars: Int, for assetID: String) {
        guard let asset = asset(id: assetID) else { return }
        let rating = PHAsset.Rating(rawValue: stars) ?? .unset
        intendedRatings[assetID] = rating.rawValue
        enqueueWrite { [self] in
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest(for: asset).rating = rating
                }
            } catch {
                if intendedRatings[assetID] == rating.rawValue { intendedRatings[assetID] = nil }
            }
        }
    }

    /// Ta sama gwiazdka dla wielu zdjęć **jedną zmianą** w Photos. Po jednej
    /// na zdjęcie oznaczało tyle samo zapisów i tyle samo powiadomień
    /// wracających do aplikacji — przy zaznaczeniu kilkuset zdjęć okno
    /// przeliczało się kilkaset razy.
    func setRating(_ stars: Int, for assetIDs: [String]) {
        let rating = PHAsset.Rating(rawValue: stars) ?? .unset
        let assets = assetIDs.compactMap(asset(id:))
        guard !assets.isEmpty else { return }
        for asset in assets { intendedRatings[asset.localIdentifier] = rating.rawValue }
        enqueueWrite { [self] in
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for asset in assets { PHAssetChangeRequest(for: asset).rating = rating }
                }
            } catch {
                for asset in assets where intendedRatings[asset.localIdentifier] == rating.rawValue {
                    intendedRatings[asset.localIdentifier] = nil
                }
            }
        }
    }

    /// Zapisy do Photos idą po kolei. Równoległe mogłyby dotrzeć w odwrotnej
    /// kolejności — Photos zostałby przy 4, choć ostatnio zapisaliśmy 3 — a przy
    /// oznaczeniach dwa szybkie `X` założyłyby dwa albumy o tej samej nazwie.
    private var writeChain: Task<Void, Never>?

    private func enqueueWrite(_ work: @escaping @MainActor () async -> Void) {
        let previous = writeChain
        writeChain = Task {
            await previous?.value
            await work()
        }
    }

    /// Ukrycie zdjęcia przez `PHAsset.isHidden`.
    ///
    /// **Sprawdzone empirycznie: system pyta o zgodę za każdym wywołaniem**,
    /// niezależnie od nadanego wcześniej dostępu do biblioteki — Apple
    /// traktuje ukrycie jak operację destrukcyjną, tak samo jak kasowanie,
    /// i wymaga potwierdzenia przy każdym zdjęciu, nie raz na aplikację.
    ///
    /// Dlatego funkcja **nie jest dziś podpięta pod żadne pojedyncze
    /// oznaczenie do usunięcia** — próba (X w GridView/CullView/Preview
    /// Inspector, zbiorcze oznaczenie) przerywała klawiaturowe ocenianie
    /// oknem systemowym po każdym kliknięciu, co zabija cały sens szybkiego
    /// przechodzenia przez archiwum. Oznaczenie jedzie zamiast tego albumem
    /// „lightbrary – to delete" — patrz `setMarkedForDeletion`.
    ///
    /// Funkcja zostaje, bo działa i może się przydać w innej roli: jako
    /// **jedna, świadoma, zbiorcza operacja** wywoływana rzadko (na przykład
    /// przy przeglądzie w `DeletionReview`, gdzie i tak pyta się o zgodę na
    /// kasowanie) — tam jedno okno na sto zdjęć jest do przyjęcia, jedno na
    /// każde pojedyncze `X` nie jest.
    func setHidden(_ hidden: Bool, for assetIDs: [String]) async {
        let assets = assetIDs.compactMap(asset(id:))
        guard !assets.isEmpty else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            for asset in assets {
                PHAssetChangeRequest(for: asset).isHidden = hidden
            }
        }
    }

    // MARK: - Oznaczenie do skasowania

    /// Oznaczenie do skasowania jedzie **albumem**, nie tylko plikiem wymiany.
    ///
    /// Skasować po cichu się nie da — system pyta o zgodę przy każdym
    /// wywołaniu, i słusznie. Ale samo *oznaczenie* to przynależność do
    /// albumu, którą iCloud synchronizuje sam, bez folderu wymiany, a człowiek
    /// widzi ją też w systemowych Zdjęciach. Kasowanie zostaje jedną, świadomą
    /// operacją w `DeletionReview`: jedno okno zgody na całą pulę.
    ///
    /// Sprawdzone na macOS 27: dwa oznaczenia pod rząd bez okna zgody. Po
    /// `isHidden` wiadomo, że z nagłówków SDK tego nie widać — trzeba było
    /// sprawdzić na żywo.
    static let deletionAlbumTitle = "lightbrary – to delete"

    /// Synchroniczne z tego samego powodu co `setRating`: zamiar musi być
    /// znany od razu, a sam zapis idzie w kolejce za poprzednimi.
    func setMarkedForDeletion(_ marked: Bool, for assetIDs: [String]) {
        for id in assetIDs { intendedMarks[id] = marked }
        enqueueWrite { [self] in await applyMark(marked, for: assetIDs) }
    }

    private func applyMark(_ marked: Bool, for assetIDs: [String]) async {
        let assets = assetIDs.compactMap(asset(id:)) as NSArray
        guard assets.count > 0 else { return }
        // Po nazwie, nie po identyfikatorze: `localIdentifier` albumu jest inny
        // na każdym urządzeniu. Gdyby mimo wszystko powstały dwa (dwa
        // urządzenia naraz), zdejmujemy ze wszystkich, a dokładamy do pierwszego.
        let albums = Self.deletionAlbums()
        if !marked && albums.isEmpty { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if marked {
                    let request = albums.first.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                        ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                            withTitle: Self.deletionAlbumTitle)
                    request.addAssets(assets)
                } else {
                    for album in albums {
                        PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets)
                    }
                }
            }
        } catch {
            for id in assetIDs where intendedMarks[id] == marked { intendedMarks[id] = nil }
        }
    }

    private static func deletionAlbumMembers() -> Set<String> {
        var members = Set<String>()
        for album in deletionAlbums() {
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                members.insert(asset.localIdentifier)
            }
        }
        return members
    }

    private static func deletionAlbums() -> [PHAssetCollection] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", deletionAlbumTitle)
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options
        )
        var albums: [PHAssetCollection] = []
        result.enumerateObjects { album, _, _ in albums.append(album) }
        return albums
    }
}

/// PhotoKit woła obserwatora z kolejki w tle i wymaga `NSObject`. Osobny mały
/// obiekt zamiast dziedziczenia `PhotoLibrary` po `NSObject`.
private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: (PHChange) -> Void

    init(onChange: @escaping (PHChange) -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ change: PHChange) {
        onChange(change)
    }
}

/// Przenosi przez granicę wątku obiekt, o którym wiemy, że jest bezpieczny,
/// choć kompilator tego nie widzi (`PHFetchResult`).
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
