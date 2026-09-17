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
                    "Nic nie zaznaczono",
                    systemImage: "photo.on.rectangle",
                    description: Text("Kliknij kafelek w siatce, żeby zobaczyć go tutaj.")
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("PODGLĄD")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(selectionCount > 1
                 ? "zaznaczono \(selectionCount) · ocena dotyczy pierwszego"
                 : "klik zaznacza · dwuklik pełny ekran")
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

    private func stamp(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.66), in: Capsule())
    }

    /// Liczba, przez którą zdjęcie stoi w tym miejscu zbioru — ta sama, którą
    /// kafelek pokazuje przy najechaniu.
    private func measureNote(_ asset: PHAsset) -> String? { nil }

    private func rating(_ asset: PHAsset) -> some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= (review?.stars ?? 0) ? "star.fill" : "star")
                    .font(.system(size: 16))
                    .foregroundStyle(value <= (review?.stars ?? 0)
                                     ? Color.yellow : Color.secondary.opacity(0.35))
                    .onTapGesture {
                        Review.upsert(assetID: asset.localIdentifier, in: context) {
                            $0.set(Double(value))
                        }
                    }
            }
            if let review, review.isRated {
                Text(String(format: "%.2f", review.weight))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                Review.upsert(assetID: asset.localIdentifier, in: context) {
                    $0.markedForDeletion.toggle()
                }
            } label: {
                Label("oznacz do usunięcia",
                      systemImage: review?.markedForDeletion == true ? "trash.fill" : "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
#endif
