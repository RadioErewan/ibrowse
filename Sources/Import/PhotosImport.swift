#if os(macOS)
import Foundation
import Photos

/// Import wybranych plików do biblioteki Zdjęć.
///
/// Biblioteka dostaje **kopię**: `shouldMoveFile = false`, a folder jest
/// otwarty zakładką tylko do odczytu, więc plik na dysku zostaje tam, gdzie
/// był, w tym samym stanie. Pominięte nie idą wcale.
@MainActor
final class PhotosImport: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(imported: Int, failed: Int, album: String, saved: Int64)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Paczki po kilka zdjęć: jedna zmiana biblioteki na zdjęcie jest
    /// powolna, a jedna na wszystko przepada w całości przez jeden zły plik.
    private static let batch = 8

    func run(_ session: ImportSession, album title: String, convert mode: HEICMode?) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.forgetVanished(in: session)
        let items = session.pending
        guard !items.isEmpty else {
            phase = .finished(imported: 0, failed: 0, album: title, saved: 0)
            return
        }
        phase = .running(done: 0, total: items.count)

        let album: PHAssetCollection?
        do {
            album = title.isEmpty ? nil : try await Self.album(named: title)
        } catch {
            ImportSession.log.error("album failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }

        var imported = 0
        var failed = 0
        var saved: Int64 = 0
        for start in stride(from: 0, to: items.count, by: Self.batch) {
            let slice = Array(items[start..<min(start + Self.batch, items.count)])
            // Konwersja poza głównym wątkiem: RAW wywołuje się sekundę i dłużej.
            let chunk = await Task.detached(priority: .userInitiated) {
                slice.map { ImportPlan.make(for: $0, mode: mode) }
            }.value
            // Pliki tymczasowe znikają po paczce, udanej czy nie — Zdjęcia
            // mają już swoją kopię albo jej nie dostaną.
            defer {
                for file in chunk.flatMap(\.temporary) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            let ratings = Dictionary(uniqueKeysWithValues: slice.map { ($0.id, session.decision(for: $0).stars) })
            let savings = Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, $0.convertedFrom - $0.convertedTo) })
            do {
                for (id, assetID) in try await Self.create(chunk, ratings: ratings, album: album) {
                    saved += savings[id] ?? 0
                    session.markImported(id, as: assetID)
                    imported += 1
                }
            } catch {
                // Paczka przepada w całości — powtarzamy po jednym, żeby
                // jeden uszkodzony plik nie zabrał ze sobą siedmiu dobrych.
                ImportSession.log.error("batch failed: \(error.localizedDescription, privacy: .public)")
                for item in chunk {
                    if let (id, assetID) = try? await Self.create([item], ratings: ratings, album: album).first {
                        session.markImported(id, as: assetID)
                        saved += savings[id] ?? 0
                        imported += 1
                    } else {
                        ImportSession.log.error("file failed: \(item.id, privacy: .private)")
                        failed += 1
                    }
                }
            }
            phase = .running(done: min(start + Self.batch, items.count), total: items.count)
        }
        session.flush()
        phase = .finished(imported: imported, failed: failed, album: title, saved: saved)
    }

    func reset() { phase = .idle }

    /// Zdjęcie zaimportowane, a potem skasowane w Zdjęciach, ma prawo pójść
    /// jeszcze raz — inaczej zostałoby na zawsze „w bibliotece", której nie ma.
    ///
    /// Wołane przy otwarciu folderu i przy każdym powrocie do aplikacji —
    /// nie tylko przy imporcie, bo przy wszystkim już zaimportowanym przycisk
    /// importu jest wyłączony i do sprawdzenia nigdy by nie doszło.
    static func forgetVanished(in session: ImportSession) {
        let recorded = session.decisions.compactMap { id, decision in
            decision.imported.map { (id, $0) }
        }
        guard !recorded.isEmpty else { return }
        let alive = PHAsset.fetchAssets(withLocalIdentifiers: recorded.map(\.1), options: nil)
        var present = Set<String>()
        alive.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        for (id, assetID) in recorded where !present.contains(assetID) {
            session.markImported(id, as: nil)
        }
    }

    /// Album o tej nazwie — istniejący albo nowy. Drugi import tego samego
    /// folderu dokłada do tego samego albumu zamiast tworzyć bliźniaka.
    private static func album(named title: String) async throws -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        if let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options
        ).firstObject {
            return existing
        }

        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            box.id = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = box.id else { return nil }
        return PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil
        ).firstObject
    }

    /// Jedna zmiana biblioteki na paczkę. Para RAW+JPEG idzie jako jedno
    /// zdjęcie z dwoma zasobami — JPEG jako obraz, RAW jako alternatywa —
    /// tak samo, jak robi to import z aparatu. Co dokładnie idzie, mówi
    /// `ImportPlan` — z konwersją do HEIC albo bez.
    private static func create(
        _ plans: [ImportPlan], ratings: [String: Int], album: PHAssetCollection?
    ) async throws -> [(String, String)] {
        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            var placeholders: [PHObjectPlaceholder] = []
            for item in plans {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: item.photo, options: copy(named: item.photoName))
                if let raw = item.alternate {
                    request.addResource(with: .alternatePhoto, fileURL: raw, options: copy(named: raw.lastPathComponent))
                }
                if let stars = ratings[item.id], stars > 0, let rating = PHAsset.Rating(rawValue: stars) {
                    request.rating = rating
                }
                if let placeholder = request.placeholderForCreatedAsset {
                    placeholders.append(placeholder)
                    box.created.append((item.id, placeholder.localIdentifier))
                }
            }
            if let album, let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets(placeholders as NSArray)
            }
        }
        return box.created
    }

    private static func copy(named name: String) -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.shouldMoveFile = false
        options.originalFilename = name
        return options
    }

    /// Wynik spod bloku zmian. Blok biegnie poza głównym wątkiem i nie może
    /// pisać do zmiennych lokalnych wołającego.
    private final class Box: @unchecked Sendable {
        var id: String?
        var created: [(String, String)] = []
    }
}
#endif
