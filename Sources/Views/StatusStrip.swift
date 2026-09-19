#if os(macOS)
import SwiftUI

/// Pasek stanu na dole okna — pokazuje się tylko wtedy, gdy coś trwa.
///
/// Postęp siedział dotąd w belce narzędziowej, w kontrolce szerokiej na sto
/// punktów. Mieścił się, ale nie odpowiadał na pytanie „czy to jeszcze
/// działa" — przy liczeniu 25 tysięcy odcisków albo pobieraniu 50 MB to
/// jedyne pytanie, jakie się zadaje.
///
/// Na dole, bo tam patrzy się po zleceniu roboty, a nie w trakcie oglądania
/// zdjęć. I znika bez śladu, gdy nie ma o czym mówić.
struct StatusStrip: View {
    @ObservedObject var similarity: Similarity
    @ObservedObject var sync: LibrarySync

    /// Co zrobić, gdy w folderze leży nowszy plik.
    var onRead: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                progress
                Spacer(minLength: 12)
                exchange
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// Prawa strona mówi **zawsze**, bo odpowiada na pytanie zadawane po
    /// powrocie do komputera: czy to, co widzę, jest aktualne. Synchronizacja
    /// jest ręczna po obu stronach i bez tego nie da się tego wiedzieć —
    /// oceniasz na telefonie, siadasz do Maca i wygląda, jakby praca przepadła.
    @ViewBuilder
    private var exchange: some View {
        HStack(spacing: 8) {
            if let pending = sync.pending {
                Label {
                    Text("newer in the folder: \(pending.name), \(pending.modified, style: .relative)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.yellow)
                .lineLimit(1)

                Button("read", action: onRead)
                    .buttonStyle(.link)
                    .font(.caption)
            } else if let read = sync.lastRead {
                Text("shared file · read \(read, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("shared file · never read")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if similarity.isWorking {
            strip(
                title: "computing visual fingerprints",
                detail: "\(similarity.progress) / \(similarity.total)",
                fraction: Double(similarity.progress) / Double(max(similarity.total, 1))
            )
        } else if sync.isWorking {
            strip(title: sync.stage ?? "syncing", detail: nil, fraction: nil)
        } else if let note = similarity.note {
            done(note)
        }
    }

    /// Zakończenie też jest wiadomością. Bez tego operacja, która nie miała
    /// nic do zrobienia, kończyła się zniknięciem paska — obrazem
    /// nieodróżnialnym od awarii.
    private func done(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.caption).lineLimit(1)
        }
        .transition(.opacity)
    }

    /// Postęp określony pokazujemy paskiem, nieokreślony — kręciołkiem.
    /// Udawany pasek przy nieznanym czasie jest gorszy od żadnego: sugeruje
    /// wiedzę, której nie mamy.
    private func strip(title: String, detail: String?, fraction: Double?) -> some View {
        HStack(spacing: 10) {
            if let fraction {
                ProgressView(value: fraction).frame(width: 130)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).font(.caption).lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
    }
}
#endif
