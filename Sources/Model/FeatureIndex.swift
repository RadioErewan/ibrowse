import Foundation
import SwiftData

/// Cechy policzone przez system, wyjęte z bazy **raz** i trzymane jako zwykłe
/// struktury.
///
/// Mieszkają w `Review`, bo tamtędy jadą na telefon — ale sięganie po nie
/// przez `@Query` byłoby zabójcze. Rekordów z cechami jest tyle, co zdjęć
/// (25 tysięcy), a zapytanie unieważnia widok przy **każdym** zapisie: każda
/// ocena przebudowywałaby całą siatkę razem ze słownikiem. Do tego ocenianie
/// pyta o rekordy niosące decyzję i celowo ich nie widzi.
///
/// Dlatego cechy czytamy osobno i jednorazowo. Zmieniają się tylko przy
/// wczytaniu z baz systemu albo przy synchronizacji — czyli wtedy, gdy ktoś
/// o to wprost poprosi, a nie w trakcie pracy.
@MainActor
final class FeatureIndex: ObservableObject {

    /// Sam pomiar, bez obiektu modelu. Struktura nie trzyma kontekstu,
    /// nie unieważnia widoków i mieści się w słowniku, po którym wolno
    /// chodzić w pętli.
    struct Row {
        var sharpness: Double = 0
        var exposure: Double = 0
        var faces: Int = 0
        var eyesClosed: Int = 0
        var smiles: Int = 0
        var isScreenshot: Bool = false
    }

    @Published private(set) var rows: [String: Row] = [:]

    /// Rośnie przy każdym wczytaniu. Filtry używają go jako podpisu pamięci
    /// podręcznej — bez tego zbiór roboczy nie zauważyłby świeżych cech.
    @Published private(set) var revision = 0

    var count: Int { rows.count }
    var isEmpty: Bool { rows.isEmpty }

    subscript(id: String) -> Row? { rows[id] }

    func load(context: ModelContext) {
        let descriptor = FetchDescriptor<Review>(
            predicate: #Predicate {
                $0.sharpness > 0 || $0.exposure > 0 || $0.faces > 0 || $0.isScreenshot
            }
        )
        let found = (try? context.fetch(descriptor)) ?? []

        rows = Dictionary(
            found.map { review in
                (review.assetID, Row(
                    sharpness: review.sharpness,
                    exposure: review.exposure,
                    faces: review.faces,
                    eyesClosed: review.eyesClosed,
                    smiles: review.smiles,
                    isScreenshot: review.isScreenshot
                ))
            },
            uniquingKeysWith: { a, _ in a }
        )
        revision += 1
    }
}
