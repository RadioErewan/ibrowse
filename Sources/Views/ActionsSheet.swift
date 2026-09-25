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

    /// Czy zakładka pair-up jest właśnie na ekranie z niedokończonym
    /// pojedynkiem. Zmiana progu przebudowuje serie od zera — skład grupy
    /// pod ekranem potrafi się wtedy zmienić i podmienić parę, na którą
    /// ktoś właśnie patrzy, zanim zdąży wydać werdykt. Na Macu ten sam
    /// suwak mieszka w nagłówku porównania i jest widoczny tylko podczas
    /// aktywnego pojedynku, więc kto go rusza, świadomie na to patrzy —
    /// tu, w arkuszu dostępnym z każdej zakładki, tej świadomości nie ma.
    ///
    /// Sama zakładka to za mało: przy „All resolved" na ekranie nie ma żadnej
    /// pary, a suwak i tak stał zablokowany — akurat wtedy, gdy przegrupowanie
    /// jest jedyną drogą do kolejnych serii.
    var onPairTab: Bool

    @Query private var series: [Series]
    @AppStorage("pair.minimumSize") private var minimumSize = 3

    private var pairInProgress: Bool {
        onPairTab && series.contains {
            !$0.isResolved && $0.members.count >= minimumSize && $0.isPlayable(in: library)
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var choosingFolder = false
    /// Nazwa folderu jest droga do ustalenia (rozwiązanie zakładki
    /// i zdjęcie uprawnienia), więc nie liczymy jej przy każdym rysowaniu.
    @State private var folderName: String?

    private var busy: Bool { similarity.isWorking || sync.isWorking }

    var body: some View {
        NavigationStack {
            List {
                Section("Sync") {
                    LabeledContent("Shared folder") {
                        Text(folderName ?? "not chosen")
                            .foregroundStyle(folderName == nil ? .orange : .secondary)
                    }
                    Button {
                        choosingFolder = true
                    } label: {
                        Label(
                            folderName == nil ? "choose folder…" : "change folder…",
                            systemImage: "folder"
                        )
                    }
                    Button {
                        Task {
                            await sync.synchronise(context: context, similarity: similarity, library: library)
                            // Tylko odczyt — patrz komentarz przy tym samym
                            // wywołaniu w `App.swift`.
                            _ = albums.pull(into: context)
                            folderName = SyncFolder.displayName
                        }
                    } label: {
                        Label("sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(folderName == nil || busy)

                    if sync.isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(sync.stage ?? "working…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else if let note = sync.summary {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Choose the same folder as on the other device — ideally in iCloud Drive. Fingerprints and ratings arrive from there, so the phone doesn't have to compute them.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Visual fingerprints") {
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
                            Label("compute fingerprints", systemImage: "wand.and.stars")
                        }
                        .disabled(busy)
                    }

                    if !similarity.groups.isEmpty {
                        LabeledContent("Bursts", value: "\(similarity.groups.count)")
                    }

                    // Na Macu ta sama suwak mieszka w nagłówku pair-up, bo tam
                    // jest zawsze na ekranie. Na telefonie pair-up nie ma
                    // stałego nagłówka poza aktywnym pojedynkiem, więc to
                    // jedyne miejsce, gdzie się w ogóle da to zmienić —
                    // bez niego serie raz rozstrzygnięte nigdy się nie
                    // przegrupowują, nawet gdy nic nowego nie zostało do zrobienia.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("sensitivity")
                            Spacer()
                            Text(String(format: "%.2f", similarity.threshold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.callout)
                        Slider(value: $similarity.threshold, in: 0.25...0.75, step: 0.01)
                            .disabled(pairInProgress)
                        if pairInProgress {
                            Text("Finish the current duel first — changing this reshuffles bursts.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
