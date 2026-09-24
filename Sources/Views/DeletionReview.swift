import Photos
import SwiftData
import SwiftUI

/// Ostatni przegląd przed usunięciem.
///
/// Oznaczanie i usuwanie są celowo rozdzielone: oznaczasz szybko, w rytmie
/// przeglądania, a kasujesz świadomie, widząc całą pulę naraz. Samo usunięcie
/// idzie przez PhotoKit, więc system pokazuje własne potwierdzenie, a zdjęcia
/// lądują w „Ostatnio usunięte" i przez 30 dni da się je odzyskać.
struct DeletionReview: View {
    @ObservedObject var library: PhotoLibrary
    let reviews: [Review]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var isDeleting = false
    @State private var error: String?

    private var assets: [PHAsset] {
        let ids = Set(reviews.map(\.assetID))
        return library.assets.filter { ids.contains($0.localIdentifier) }
    }

    /// Serie liczą się w całości — patrz `PhotoLibrary.deletionSize`.
    @State private var sizes: [String: Int] = [:]

    private var photoCount: Int {
        assets.reduce(0) { $0 + (sizes[$1.localIdentifier] ?? 1) }
    }

    private var hasBursts: Bool { photoCount != assets.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(hasBursts
                     ? "To delete: \(photoCount) photos (\(assets.count) marked, bursts in full)"
                     : "To delete: \(assets.count)")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        // Kwadrat z **całym** kadrem, nie wycinkiem — przed
                        // skasowaniem trzeba widzieć, co się kasuje. Przycisk
                        // przypięty do rogu kwadratu; wcześniej komórka była
                        // szersza od obrazka i przycisk wisiał obok zdjęcia.
                        Color.black
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                AssetImage(
                                    asset: asset,
                                    library: library,
                                    targetSize: CGSize(width: 320, height: 320)
                                )
                            }
                            .clipped()
                            .overlay(alignment: .bottomLeading) {
                                if let size = sizes[asset.localIdentifier], size > 1 {
                                    Label("burst · \(size)", systemImage: "square.stack.3d.down.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.red.opacity(0.8), in: Capsule())
                                        .padding(4)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    unmark(asset)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                        #if os(iOS)
                                        .font(.title2)
                                        #endif
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                                .help("Unmark")
                            }
                    }
                }
                .padding(10)
            }

            Divider()

            // Na telefonie opis nad przyciskiem, nie obok — w jednym rzędzie
            // nie mieściło się ani jedno, ani drugie.
            #if os(macOS)
            HStack {
                footerNote
                Spacer()
                deleteButton
            }
            .padding(14)
            #else
            VStack(alignment: .leading, spacing: 10) {
                footerNote
                deleteButton
                    .frame(maxWidth: .infinity)
            }
            .padding(14)
            #endif
        }
        // Minimum tylko na Macu: na iPhonie 560 punktów to więcej niż ekran,
        // i całe okno wyjeżdżało poza lewą krawędź.
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
        .task(id: assets.map(\.localIdentifier)) {
            sizes = Dictionary(uniqueKeysWithValues: assets.map {
                ($0.localIdentifier, library.deletionSize(of: $0))
            })
        }
    }

    @ViewBuilder
    private var footerNote: some View {
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        } else {
            Text(hasBursts
                 ? "A burst is deleted as a whole. Deleted photos go to Recently Deleted and can be restored from there for 30 days."
                 : "Deleted photos go to Recently Deleted and can be restored from there for 30 days.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task { await deleteAll() }
        } label: {
            if isDeleting {
                ProgressView().controlSize(.small)
            } else {
                Text("Delete \(photoCount)")
                    #if os(iOS)
                    .frame(maxWidth: .infinity)
                    #endif
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(assets.isEmpty || isDeleting || sizes.count != assets.count)
    }

    private func unmark(_ asset: PHAsset) {
        Review.upsert(assetID: asset.localIdentifier, in: context) {
            $0.markedForDeletion = false
        }
        library.setMarkedForDeletion(false, for: [asset.localIdentifier])
    }

    private func deleteAll() async {
        isDeleting = true
        error = nil
        let removed = assets
        do {
            try await library.delete(removed)
            // Oceny usuniętych zdjęć nie mają już do czego się odnosić.
            for review in reviews { context.delete(review) }
            try? context.save()
            dismiss()
        } catch {
            self.error = "Couldn't delete: \(error.localizedDescription)"
        }
        isDeleting = false
    }
}
