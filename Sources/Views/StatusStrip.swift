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
    @ObservedObject var albums: AlbumSync

    var body: some View {
        if similarity.isWorking {
            strip(
                title: "liczę odciski wizualne",
                detail: "\(similarity.progress) / \(similarity.total)",
                fraction: Double(similarity.progress) / Double(max(similarity.total, 1))
            )
        } else if sync.isWorking {
            strip(title: sync.stage ?? "synchronizuję", detail: nil, fraction: nil)
        } else if albums.isSyncing {
            strip(title: "zapisuję oceny do albumów", detail: nil, fraction: nil)
        } else if let note = similarity.note {
            done(note)
        }
    }

    /// Zakończenie też jest wiadomością. Bez tego operacja, która nie miała
    /// nic do zrobienia, kończyła się zniknięciem paska — obrazem
    /// nieodróżnialnym od awarii.
    private func done(_ text: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text).font(.callout)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Postęp określony pokazujemy paskiem, nieokreślony — kręciołkiem.
    /// Udawany pasek przy nieznanym czasie jest gorszy od żadnego: sugeruje
    /// wiedzę, której nie mamy.
    private func strip(title: String, detail: String?, fraction: Double?) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 180)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(title)
                    .font(.callout)
                if let detail {
                    Text(detail)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
#endif
