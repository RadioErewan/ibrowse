#if os(iOS)
import SwiftData
import SwiftUI

/// Akcje i ustawienia na telefonie — **arkusz, nie menu**.
///
/// To już trzeci raz, gdy `Menu` na iOS okazało się złym pojemnikiem. Menu
/// zamyka się przy każdej przebudowie widoku, a tutaj przebudowa jest pewna:
/// liczba serii i postęp liczenia zmieniają się w trakcie. Stąd pulsowanie
/// i wrażenie, że nic nie działa.
///
/// Arkusz ma własny cykl życia. Przeżywa zmianę stanu, mieści postęp, mieści
/// wybór folderu przez systemowy wybierak — wszystko to, czego menu nie umie.
struct ActionsSheet: View {
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var similarity: Similarity
    @ObservedObject var albums: AlbumSync
    @ObservedObject var sync: LibrarySync

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var choosingFolder = false
    /// Nazwa folderu jest droga do ustalenia (rozwiązanie zakładki
    /// i zdjęcie uprawnienia), więc nie liczymy jej przy każdym rysowaniu.
    @State private var folderName: String?

    private var busy: Bool { similarity.isWorking || sync.isWorking || albums.isSyncing }

    var body: some View {
        NavigationStack {
            List {
                Section("Synchronizacja") {
                    LabeledContent("Folder wymiany") {
                        Text(folderName ?? "nie wskazany")
                            .foregroundStyle(folderName == nil ? .orange : .secondary)
                    }
                    Button {
                        choosingFolder = true
                    } label: {
                        Label(
                            folderName == nil ? "wskaż folder…" : "zmień folder…",
                            systemImage: "folder"
                        )
                    }
                    Button {
                        Task {
                            // Plik **przed** albumami, i to nie jest obojętne.
                            // Album niesie samą gwiazdkę i przy zasiewie
                            // stempluje ocenę bieżącym czasem — czyli zawsze
                            // nowszym niż dokładna waga z pliku. Odwrotna
                            // kolejność podmieniała 3,75 na okrągłe 4.
                            await sync.synchronise(context: context, similarity: similarity, library: library)
                            _ = albums.pull(into: context)
                            await albums.push(from: context)
                            folderName = SyncFolder.displayName
                        }
                    } label: {
                        Label("synchronizuj teraz", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(folderName == nil || busy)

                    if sync.isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(sync.stage ?? "pracuję…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else if let note = sync.summary {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Wskaż ten sam folder co na drugim urządzeniu — najlepiej w iCloud Drive. Odciski i oceny przyjadą stamtąd, więc telefon nie musi ich liczyć.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Odciski wizualne") {
                    if similarity.isWorking {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(
                                value: Double(similarity.progress),
                                total: Double(max(similarity.total, 1))
                            )
                            Text("\(similarity.progress) / \(similarity.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            Task {
                                await similarity.computeFingerprints(
                                    for: library.assets, library: library, context: context
                                )
                            }
                        } label: {
                            Label("policz odciski", systemImage: "wand.and.stars")
                        }
                        .disabled(busy)
                    }

                    if !similarity.groups.isEmpty {
                        LabeledContent("Serie", value: "\(similarity.groups.count)")
                    }
                }
            }
            .navigationTitle("Akcje")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gotowe") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { folderName = SyncFolder.displayName }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            // Wybierak oddaje adres z uprawnieniem tylko na czas tego
            // wywołania — zakładkę trzeba zrobić od razu, w tym miejscu.
            let granted = url.startAccessingSecurityScopedResource()
            try? SyncFolder.remember(url)
            if granted { url.stopAccessingSecurityScopedResource() }
            folderName = SyncFolder.displayName
        }
    }
}
#endif
