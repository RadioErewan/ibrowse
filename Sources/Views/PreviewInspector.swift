#if os(macOS)
import Photos
import SwiftData
import SwiftUI

/// Trzecia kolumna przestrzeni roboczej: podgląd zaznaczonego zdjęcia razem
/// z oceną i metadanymi.
///
/// Powstała z rozstrzygnięcia, że okno jest trzykolumnowe, a pojedyncze zdjęcie
/// nie jest osobnym trybem, tylko powiększeniem tego, co zaznaczone. Dzięki
/// temu znika przełączanie: klikasz kafelek i od razu widzisz duży kadr,
/// gwiazdki i technikę, bez opuszczania siatki.
///
/// Podgląd **rośnie razem z oknem**. Sekcje metadanych biorą tyle, ile mają
/// treści, a cała reszta wysokości należy do zdjęcia — na wyższym ekranie
/// rośnie kadr, nie puste miejsce pod tabelą.
struct PreviewInspector: View {
    let asset: PHAsset?
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var metadata: MetadataIndex

    /// Ile zdjęć jest zaznaczonych. Przy wielu podgląd pokazuje pierwsze,
    /// ale ocena dotyczyłaby tylko jego — więc mówimy o tym wprost, zamiast
    /// udawać, że gwiazdki działają na całą pulę.
    let selectionCount: Int

    var onFullScreen: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Review> { $0.isRated || $0.markedForDeletion })
    private var reviews: [Review]

    private var review: Review? {
        guard let asset else { return nil }
        return reviews.first { $0.assetID == asset.localIdentifier }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let asset {
                preview(asset)
                Divider()
                rating(asset)
                Divider()
                MetadataPanel(asset: asset, index: metadata)
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "photo.on.rectangle",
                    description: Text("Click a tile in the grid to see it here.")
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("PREVIEW")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(selectionCount > 1
                 ? "selected \(selectionCount) · rating applies to the first"
                 : "click selects · double-click for full screen")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Zdjęcie na czerni i **z priorytetem układu**, żeby przy rozciąganiu okna
    /// rosło ono, a nie odstęp pod tabelą metadanych.
    private func preview(_ asset: PHAsset) -> some View {
        ZStack {
            Color.black
            AssetImage(
                asset: asset, library: library,
                targetSize: CGSize(width: 1600, height: 1600)
            )
        }
        .frame(minHeight: 260)
        .layoutPriority(1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onFullScreen() }
        .overlay(alignment: .bottomLeading) { stamps(asset) }
    }

    /// Podpisy na zdjęciu zawsze na podkładce — nad fotografią biały tekst bez
    /// tła ginie na pierwszym jasnym kadrze.
    @ViewBuilder
    private func stamps(_ asset: PHAsset) -> some View {
        HStack(spacing: 6) {
            if let note = measureNote(asset) { stamp(note) }
            stamp("Z — 1:1")
        }
        .padding(8)
    }

    /// Dwa przeciążenia celowo. `LocalizedStringKey` dla stałych napisów jak
    /// „Z — 1:1" — patrz komentarz przy `group()` w `FilterPanel`. Osobne
    /// przeciążenie na zwykły `String` dla treści policzonej w locie
    /// (`measureNote`), której i tak nie wolno szukać w katalogu tłumaczeń —
    /// to nie jest klucz, to gotowy wynik.
    private func stamp(_ text: LocalizedStringKey) -> some View {
        stampLabel(Text(text))
    }

    private func stamp(_ text: String) -> some View {
        stampLabel(Text(text))
    }

    private func stampLabel(_ text: Text) -> some View {
        text
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.66), in: Capsule())
    }

    /// Liczba, przez którą zdjęcie stoi w tym miejscu zbioru — ta sama, którą
    /// kafelek pokazuje przy najechaniu.
    private func measureNote(_ asset: PHAsset) -> String? { nil }

    /// Ten sam rząd co w ocenianiu i ta sama kolejność co w skali filtru:
    /// kosz, zero, pięć gwiazdek. Trzy miejsca, jeden rysunek.
    private func rating(_ asset: PHAsset) -> some View {
        HStack(spacing: 6) {
            cell(symbol: review?.markedForDeletion == true ? "trash.fill" : "trash",
                 tint: AnyShapeStyle(Color.red), isOn: review?.markedForDeletion == true, help: "to delete") {
                let marked = Review.upsert(assetID: asset.localIdentifier, in: context) {
                    $0.markedForDeletion.toggle()
                }.markedForDeletion
                Task { await library.setMarkedForDeletion(marked, for: [asset.localIdentifier]) }
            }

            // Ocena zerowa to pięć zgaszonych gwiazdek, a wyzerowanie —
            // kliknięcie w zapaloną jedynkę. Patrz komentarz w `CullView`.
            ForEach(1...5, id: \.self) { value in
                let lit = value <= (review?.stars ?? 0)
                let clears = value == 1 && review?.isRated == true && review?.stars == 1
                cell(symbol: lit ? "star.fill" : "star",
                     tint: AnyShapeStyle(Color.yellow), isOn: lit,
                     help: clears ? "clear rating" : "\(value)") {
                    let (updated, changed) = Review.upsertRating(
                        assetID: asset.localIdentifier, in: context
                    ) { $0.set(clears ? 0 : Double(value)) }
                    if changed {
                        Task { await library.setRating(updated.stars, for: asset.localIdentifier) }
                    }
                }
            }

            if let review, review.isRated {
                Text(String(format: "%.2f", review.weight))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func cell(
        symbol: String, tint: AnyShapeStyle, isOn: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundStyle(isOn ? tint : AnyShapeStyle(Color.secondary.opacity(0.35)))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
    }
}
#endif
