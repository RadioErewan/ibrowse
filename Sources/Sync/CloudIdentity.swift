import Photos

/// Tłumaczy identyfikatory zdjęć **między urządzeniami**.
///
/// `PHAsset.localIdentifier` jest lokalny — nazwa nie kłamie. To samo zdjęcie
/// z tej samej biblioteki iCloud ma inny identyfikator na Macu i na telefonie.
/// Pierwsza wersja synchronizacji założyła, że są zgodne, i skutek był dokładnie
/// taki, jakiego należało się spodziewać: 24 984 odciski z Maca dosiadły się
/// obok 7 835 policzonych na telefonie, nie trafiając w ani jedno wspólne
/// zdjęcie. Razem 32 819 wpisów o 24 984 zdjęciach.
///
/// `PHCloudIdentifier` jest tym, czym `localIdentifier` nie jest: **wspólny dla
/// wszystkich urządzeń** dzielących bibliotekę iCloud. Apple dodało to API
/// właśnie do tego zadania.
///
/// Tłumaczenie kosztuje, więc robimy je raz na synchronizację i partiami —
/// przy 25 tysiącach pozycji jedno wywołanie potrafi się zadławić.
enum CloudIdentity {
    private static let batch = 2500

    /// Lokalny → chmurowy. Używane przy zapisie pliku wymiany.
    static func cloudIDs(for localIDs: [String]) -> [String: String] {
        guard !localIDs.isEmpty else { return [:] }
        let library = PHPhotoLibrary.shared()
        var result: [String: String] = [:]
        result.reserveCapacity(localIDs.count)

        for chunk in localIDs.chunked(into: batch) {
            for (local, outcome) in library.cloudIdentifierMappings(forLocalIdentifiers: chunk) {
                if case .success(let cloud) = outcome {
                    result[local] = cloud.stringValue
                }
            }
        }
        return result
    }

    /// Chmurowy → lokalny. Używane przy czytaniu cudzego pliku.
    ///
    /// Brak tłumaczenia jest normalny, nie błędny: drugie urządzenie może mieć
    /// zdjęcia, których to jeszcze nie widzi, albo takie, które tu skasowano.
    /// Takie wpisy po prostu pomijamy.
    static func localIDs(for cloudIDs: [String]) -> [String: String] {
        guard !cloudIDs.isEmpty else { return [:] }
        let library = PHPhotoLibrary.shared()
        var result: [String: String] = [:]
        result.reserveCapacity(cloudIDs.count)

        for chunk in cloudIDs.chunked(into: batch) {
            let identifiers = chunk.map { PHCloudIdentifier(stringValue: $0) }
            for (cloud, outcome) in library.localIdentifierMappings(for: identifiers) {
                if case .success(let local) = outcome {
                    result[cloud.stringValue] = local
                }
            }
        }
        return result
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
