#if os(iOS)
import Photos
import SwiftUI

/// Metadane na telefonie — **arkusz na żądanie, nigdy stały pas**.
///
/// Na Macu panel może stać z boku, bo ekran jest szeroki i wolny. Na telefonie
/// każdy stały element odbiera miejsce fotografii, a to ona jest przedmiotem
/// pracy. Kto chce liczby, ten po nie sięga.
///
/// Zawartość jest z konieczności węższa niż na Macu: etykiety scen, imiona
/// i odczytany tekst leżą w bazie wewnątrz pakietu biblioteki na dysku Maca,
/// a iOS trzyma swój odpowiednik w piaskownicy Zdjęć, gdzie nie sięga żadne
/// API. Zostaje to, co daje PhotoKit i sam plik zdjęcia.
struct MetadataSheet: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss

    @State private var facts = AssetFacts()
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let filename = facts.filename {
                        LabeledContent("File", value: filename)
                    }
                    if let date = asset.creationDate {
                        LabeledContent("Date", value: date.formatted(date: .long, time: .shortened))
                    }
                    LabeledContent("Dimensions") {
                        Text("\(asset.pixelWidth) × \(asset.pixelHeight) · \(AssetFacts.megapixels(asset))")
                            .monospacedDigit()
                    }
                    let traits = AssetFacts.traits(asset)
                    if !traits.isEmpty {
                        LabeledContent("Kind", value: traits.joined(separator: " · "))
                    }
                    if asset.isFavorite {
                        LabeledContent("Favourite") { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                    }
                }

                exposure
                place
            }
            .navigationTitle("Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            facts = await AssetFacts.detailed(for: asset)
            isLoading = false
            // Nazwa miejsca dochodzi osobno, bo wymaga sieci i przychodzi
            // później niż reszta — reszta nie ma na nią czekać.
            if let named = await AssetFacts.place(for: asset) {
                facts.place = named
            }
        }
    }

    @ViewBuilder
    private var exposure: some View {
        Section("Technique") {
            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("reading file…").foregroundStyle(.secondary)
                }
            } else if let line = AssetFacts.exposureLine(
                focalLength: facts.focalLength, aperture: facts.aperture,
                shutter: facts.shutter, iso: facts.iso
            ) {
                Text(line).font(.body.monospaced())
                if let camera = facts.camera {
                    LabeledContent("Camera", value: camera)
                }
                if let lens = facts.lens {
                    LabeledContent("Lens", value: lens)
                }
            } else {
                // Oryginał siedzi w iCloud. Nie pobieramy go, bo zostałby na
                // telefonie na stałe — a PhotoKit nie daje sposobu, żeby go
                // potem usunąć.
                Text("The original isn't on this device, so I don't know the camera settings. I don't fetch it, because it would stay here for good.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var place: some View {
        if let named = facts.place {
            Section("Place") {
                Text(named)
            }
        } else if asset.location != nil {
            Section("Place") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("resolving name…").foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
