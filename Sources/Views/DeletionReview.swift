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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("To delete: \(assets.count)")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        AssetImage(
                            asset: asset,
                            library: library,
                            targetSize: CGSize(width: 320, height: 320)
                        )
                        .frame(height: 120)
                        .clipped()
                        .overlay(alignment: .topTrailing) {
                            Button {
                                unmark(asset)
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.55))
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

            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text("Deleted photos go to Recently Deleted and can be restored from there for 30 days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await deleteAll() }
                } label: {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Delete \(assets.count)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(assets.isEmpty || isDeleting)
            }
            .padding(14)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func unmark(_ asset: PHAsset) {
        Review.upsert(assetID: asset.localIdentifier, in: context) {
            $0.markedForDeletion = false
        }
        Task { await library.setMarkedForDeletion(false, for: [asset.localIdentifier]) }
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
