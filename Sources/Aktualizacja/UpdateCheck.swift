#if os(macOS)
import SwiftUI

/// Sprawdzenie, czy jest nowsza wersja — **wyłącznie na żądanie**.
///
/// Program poza sklepem nie ma kto zaktualizować, a przeciąganie kolejnych
/// obrazów DMG gubi ludzi przy zgodach systemowych. Pełnej samodzielnej
/// aktualizacji (Sparkle) tu jednak nie ma, i to jest decyzja, nie brak czasu.
///
/// Powód: dziś ta aplikacja nie wykonuje **ani jednego** połączenia sieciowego
/// i to jest najmocniejsze, co można o niej powiedzieć — zwłaszcza że prosi
/// o całą bibliotekę zdjęć i o pełny dostęp do dysku. Sprawdzanie wersji przy
/// każdym starcie zamieniłoby „nic nie opuszcza tego komputera" w „prawie nic",
/// bo serwer zobaczyłby adres i wersję każdego uruchomienia. Spis powszechny
/// użytkowników robi się wtedy sam, nawet jeśli nikt do logów nie zagląda.
///
/// Dlatego połączenie następuje tylko wtedy, gdy ktoś sam kliknie w menu.
/// Wtedy jest to jego decyzja, a nie cicha właściwość programu.
@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    /// Wersje ogłasza ten sam serwer, z którego pobiera się program.
    private static let manifest = URL(string: "https://lightbrary.app/wersja.json")!

    enum State: Equatable {
        case idle
        case checking
        /// Jest nowsza — trzymamy numer i adres, pod który wysłać.
        case available(version: String, page: URL)
        case current(version: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Czy właśnie jest co pokazać. Sterowane osobno od `state`, żeby zamknięcie
    /// okienka nie kasowało wyniku.
    @Published var isPresenting = false

    private struct Manifest: Decodable {
        let version: String
        let page: String
    }

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
    }

    func check() {
        guard state != .checking else { return }
        state = .checking
        isPresenting = true

        Task {
            do {
                // Bez pamięci podręcznej: pytanie zadaje się raz na jakiś czas
                // i zawsze chodzi o stan na teraz, a nie o to, co leżało
                // w kieszeni od poprzedniego wydania.
                var request = URLRequest(url: Self.manifest)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 15

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw Failure.serwer
                }
                let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                guard let page = URL(string: manifest.page) else { throw Failure.serwer }

                state = Self.isNewer(manifest.version, than: installedVersion)
                    ? .available(version: manifest.version, page: page)
                    : .current(version: installedVersion)
            } catch {
                state = .failed(
                    "Couldn't check. Network or server — try again later."
                )
            }
        }
    }

    private enum Failure: Error { case serwer }

    /// Porównanie numerów **po członach, liczbowo**. Tekstowo „0.1.10" wypadłoby
    /// starsze niż „0.1.9", bo znak „1" stoi przed „9" — a to dokładnie ten
    /// rodzaj usterki, która wychodzi dopiero po roku wydawania.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = installed.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// Okienko z wynikiem. Osobny widok, bo ten sam stan obsługuje cztery różne
/// komunikaty i w `App.swift` zrobiłby z tego gąszcz.
struct UpdateSheet: View {
    @ObservedObject var check = UpdateCheck.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Update").font(.headline)

            switch check.state {
            case .idle, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }

            case .current(let version):
                Text("You have the latest version (\(version)).")
                    .foregroundStyle(.secondary)

            case .available(let version, let page):
                Text("Version \(version) is out. You have \(check.installedVersion).")
                Text("Download the new image and drag it to Applications, "
                     + "replacing the previous one. Granted permissions stay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open the download page") {
                    NSWorkspace.shared.open(page)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)

            case .failed(let reason):
                Text(reason)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
#endif
