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

    @State private var facts: AssetFacts
    @State private var isLoading: Bool
    /// Panel od eksportera (schemat 6): sekcje i technika, bez oryginału.
    @State private var exported: AssetMetadata?

    /// Panel przychodzi od razu z rekordu bieżącego zdjęcia, więc arkusz
    /// otwiera się z danymi — bez mignięcia „reading file…" przy każdym (i).
    init(asset: PHAsset, panel: String) {
        self.asset = asset
        let found = AssetMetadata(json: panel)
        var facts = AssetFacts.quick(for: asset)
        if let found {
            facts.camera = found.camera
            facts.lens = found.lens
            facts.iso = found.iso
            facts.aperture = found.aperture
            facts.shutter = found.shutter
            facts.focalLength = found.focalLength
            if !found.place.isEmpty { facts.place = found.place.joined(separator: ", ") }
        }
        _facts = State(initialValue: facts)
        _exported = State(initialValue: found)
        _isLoading = State(initialValue: found?.iso == nil && found?.aperture == nil)
    }

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
                sections
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
            // Techniki od eksportera nie ma — zapas z lokalnego oryginału.
            if exported?.iso == nil && exported?.aperture == nil {
                let local = await AssetFacts.detailed(for: asset)
                facts.filename = local.filename
                if exported == nil || facts.camera == nil {
                    facts.camera = local.camera
                    facts.lens = local.lens
                    facts.iso = local.iso
                    facts.aperture = local.aperture
                    facts.shutter = local.shutter
                    facts.focalLength = local.focalLength
                }
            }
            isLoading = false
            guard facts.place == nil else { return }
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
                // Oryginał siedzi w iCloud, a eksporter nic o zdjęciu nie
                // przywiózł. Pobieramy tylko na życzenie — kopia zostaje na
                // telefonie, dopóki system nie zwolni miejsca.
                Text("The original isn't on this device, so the camera settings aren't known. "
                     + "Downloading it keeps a copy here until the system needs the space.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Download original") {
                    isLoading = true
                    Task {
                        let fetched = await AssetFacts.detailed(for: asset, allowNetwork: true)
                        facts.camera = fetched.camera
                        facts.lens = fetched.lens
                        facts.iso = fetched.iso
                        facts.aperture = fetched.aperture
                        facts.shutter = fetched.shutter
                        facts.focalLength = fetched.focalLength
                        isLoading = false
                    }
                }
            }
        }
    }

    /// Sekcje z eksportera — na telefonie dotąd ich nie było wcale.
    @ViewBuilder
    private var sections: some View {
        if let exported {
            let people = exported.people + exported.pets
            if !people.isEmpty {
                Section("People and pets") { Text(people.joined(separator: ", ")) }
            }
            if !exported.occasion.isEmpty {
                Section("Occasion") { Text(exported.occasion.joined(separator: ", ")) }
            }
            if !exported.scenes.isEmpty {
                Section("What the system sees") { Text(exported.scenes.joined(separator: ", ")) }
            }
            if !exported.words.isEmpty {
                Section("Text in the photo") {
                    Text(exported.words.joined(separator: " "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
