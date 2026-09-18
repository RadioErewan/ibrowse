import Photos
import SwiftData
import SwiftUI

/// Porównanie parami wewnątrz serii — odpowiedź na „mogą być 2-3-4 podobne,
/// nie chcę decydować, co zostaje".
///
/// Nie decydujesz, co usunąć. Odpowiadasz tylko na pytanie „które z tych dwóch
/// jest lepsze", a ranking układa się sam. Turniej idzie systemem króla wzgórza:
/// zwycięzca zostaje i mierzy się z następnym, więc seria o N zdjęciach kosztuje
/// N−1 decyzji zamiast wszystkich par.
///
/// Widok zawsze podaje **pierwszą nierozstrzygniętą serię**. Dzięki temu nie ma
/// żadnego indeksu do zapamiętywania: wracasz po tygodniu i po prostu trafiasz
/// tam, gdzie skończyłeś.
struct PairView: View {
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var similarity: Similarity

    /// Ten sam wskaźnik, którego używa ocenianie. Z pojedynku wychodzi
    /// **dotychczasowy lider** — to jego się broni, więc to on jest miejscem,
    /// w którym jesteś, gdy przełączysz się na siatkę.
    @Binding var focusID: String?
    @Environment(\.modelContext) private var context

    @Query private var series: [Series]

    @FocusState private var focused: Bool

    /// Od ilu zdjęć seria trafia do parowania.
    ///
    /// Serie dwuelementowe to jedna decyzja i znikomy zysk, a jest ich kilka
    /// tysięcy — wchodząc w tryb dostawało się ścianę banalnych par zamiast
    /// materiału, dla którego to narzędzie powstało.
    @AppStorage("pair.minimumSize") private var minimumSize = 3

    /// Nierozstrzygnięte, najliczniejsze pierwsze. Seria z dwóch zdjęć to jedna
    /// decyzja; seria z dziesięciu to materiał, przy którym ręczne przeglądanie
    /// się poddaje — i od niej chcesz zaczynać.
    private var pending: [Series] {
        series.filter { !$0.isResolved && $0.members.count >= minimumSize }
            .sorted { $0.members.count > $1.members.count }
    }

    private var current: Series? { pending.first }

    /// Postęp liczymy w obrębie tego, co faktycznie zamierzasz przejrzeć,
    /// a nie wszystkich serii — inaczej licznik stoi w miejscu.
    private var inScope: [Series] { series.filter { $0.members.count >= minimumSize } }
    private var resolvedCount: Int { inScope.count - pending.count }

    var body: some View {
        Group {
            if series.isEmpty {
                ContentUnavailableView(
                    "No bursts",
                    systemImage: "square.on.square.dashed",
                    description: Text("Compute visual fingerprints first.")
                )
            } else if let current,
                      let championID = current.championID ?? current.members.first,
                      let left = library.asset(id: championID),
                      current.members.indices.contains(current.challengerIndex),
                      let right = library.asset(id: current.members[current.challengerIndex]) {
                comparison(left: left, right: right, series: current)
            } else {
                ContentUnavailableView(
                    "All resolved",
                    systemImage: "checkmark.circle",
                    description: Text("Bursts of \(minimumSize) photos and up are reviewed. Lower the threshold to take smaller ones.")
                )
            }
        }
        .focusable()
        .focusEffectDisabled()
        // `.focusable()` pozwala przyjąć focus, ale go nie nadaje. Przy
        // przełączeniu trybu klawiatura trafiała w poprzedni widok i strzałki
        // milczały, dopóki nie kliknęło się w zdjęcie.
        .focused($focused)
        // Poza bieżącym przebiegiem układu okna, przez `DispatchQueue.main.async`
        // (nie `Task` — patrz komentarz przy tym samym wzorcu w `GridView`).
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onKeyPress(.leftArrow) { pick(left: true); return .handled }
        .onKeyPress(.rightArrow) { pick(left: false); return .handled }
        .onKeyPress(.space) { resolveCurrent(); return .handled }
        .onKeyPress(KeyEquivalent("n")) { reject(); return .handled }
        .task(id: "\(current?.persistentModelID.hashValue ?? 0)-\(current?.challengerIndex ?? 0)") {
            prefetchAhead()
            focusID = current?.championID ?? current?.members.first
        }
    }

    // MARK: - Widok

    private func comparison(left: PHAsset, right: PHAsset, series current: Series) -> some View {
        VStack(spacing: 0) {
            header(current)
            Divider()

            GeometryReader { geometry in
                let layout = Self.shouldStack(left, right, in: geometry.size)
                    ? AnyLayout(VStackLayout(spacing: 3))
                    : AnyLayout(HStackLayout(spacing: 3))

                layout {
                    side(left, isChampion: true)
                    side(right, isChampion: false)
                }
            }
            .background(.black)
        }
    }

    /// Nagłówek jest inny na każdej platformie, bo różnią się nie tylko
    /// szerokością, lecz sposobem sterowania: na Macu prowadzi klawiatura,
    /// na telefonie kciuk. Wspólny poziomy pasek rozsypywał się na telefonie
    /// na jedną literę w wierszu.
    @ViewBuilder
    private func header(_ current: Series) -> some View {
        #if os(iOS)
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text("\(current.members.count) photos")
                    .font(.subheadline.weight(.semibold))
                Text("· \(current.challengerIndex) z \(current.members.count - 1)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(resolvedCount) / \(inScope.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(resolvedCount), total: Double(max(inScope.count, 1)))

            // Na telefonie nie ma klawiatury, więc obie decyzje muszą być
            // widoczne. „To nie seria" jest osobne od „pomiń" celowo:
            // pierwsze niesie informację o jakości grupowania, drugie nie.
            HStack(spacing: 10) {
                Button("skip") { resolveCurrent() }
                    .buttonStyle(.bordered)
                Button("not a burst") { reject() }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                Spacer()

                // Próg wielkości serii mieszkał na dolnym pasku systemowym
                // i chował się pod pływającym paskiem zakładek. To miejsce
                // należy do systemu, nie do nas — więc kontrolka wraca tam,
                // gdzie jest używana, do nagłówka parowania.
                Stepper(value: $minimumSize, in: 2...12) {
                    Text("od \(minimumSize)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        #else
        HStack(spacing: 12) {
            Text("\(current.members.count) photos")
                .font(.callout.weight(.semibold))
            Text("duel \(current.challengerIndex) of \(current.members.count - 1)")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Postęp jest tu po to, żeby praca miała widoczny koniec —
            // bez niego kilka tysięcy serii wygląda jak ściana bez drzwi.
            ProgressView(value: Double(resolvedCount), total: Double(max(inScope.count, 1)))
                .frame(width: 120)
            Text("\(resolvedCount) / \(inScope.count) bursts")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            // Czułość grupowania mieszka tutaj, a nie w belce okna: dotyczy
            // wyłącznie tego trybu, a wisząc globalnie zaśmiecała widok także
            // w siatce, gdzie nie znaczy nic. Dobra wartość zależy od tego, co
            // się fotografuje — serie startów samolotu rozjeżdżają się znacznie
            // bardziej niż kilka ujęć tego samego drzewa.
            Text("sensitivity")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $similarity.threshold, in: 0.25...0.75, step: 0.01)
                .frame(width: 110)
            Text(String(format: "%.2f", similarity.threshold))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            RejectionRate()

            Divider().frame(height: 14)

            Stepper(value: $minimumSize, in: 2...12) {
                Text("from \(minimumSize) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            Text("←/→ pick the better · space to skip · N not a burst")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        #endif
    }

    private func side(_ asset: PHAsset, isChampion: Bool) -> some View {
        ZStack(alignment: .top) {
            AssetImage(asset: asset, library: library, targetSize: Self.imageSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isChampion {
                Text("current leader")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.yellow.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { pick(left: isChampion) }
    }

    /// Każda strona zajmuje połowę okna — 1400 px wystarczy, a jest wyraźnie
    /// tańsze do dociągnięcia z iCloud niż pełne 2048.
    private static let imageSize = CGSize(width: 1400, height: 1400)

    /// Dobiera układ tak, żeby zdjęcia wypełniły okno jak najpełniej.
    ///
    /// Przy podziale na pół pole na jedno zdjęcie ma proporcję `A/2` (obok
    /// siebie) albo `2A` (jedno nad drugim), gdzie `A` to proporcja okna.
    /// Wypełnienie to `min(a/A', A'/a)`, więc układ pionowy wygrywa dokładnie
    /// wtedy, gdy zdjęcia są szersze niż okno.
    private static func shouldStack(
        _ left: PHAsset, _ right: PHAsset, in size: CGSize
    ) -> Bool {
        guard size.height > 0 else { return false }
        let photoAspect = (aspect(left) + aspect(right)) / 2
        return photoAspect > size.width / size.height
    }

    private static func aspect(_ asset: PHAsset) -> CGFloat {
        guard asset.pixelHeight > 0 else { return 1 }
        return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
    }

    // MARK: - Rozstrzyganie

    private func pick(left: Bool) {
        guard let current,
              let championID = current.championID ?? current.members.first,
              current.members.indices.contains(current.challengerIndex) else { return }
        let challengerID = current.members[current.challengerIndex]

        let winnerID = left ? championID : challengerID
        let loserID = left ? challengerID : championID

        // Obie oceny muszą istnieć **zanim** policzymy zaskoczenie, bo wynik
        // pojedynku zależy od obecnych wag. Dwa osobne `nudge` nie dałyby się
        // tak zestawić.
        let winner = Review.upsert(assetID: winnerID, in: context) { _ in }
        let loser = Review.upsert(assetID: loserID, in: context) { _ in }
        Review.settleDuel(winner: winner, loser: loser)

        current.championID = winnerID
        current.challengerIndex += 1
        if current.challengerIndex >= current.members.count {
            resolveCurrent()
        } else {
            try? context.save()
        }
    }

    /// Odrzuca zestawienie jako błędne. Zapis idzie do `wasRejected`, dzięki
    /// czemu widać, ile serii przy danej czułości okazało się przypadkowych.
    private func reject() {
        guard let current else { return }
        current.wasRejected = true
        current.resolvedAt = .now
        try? context.save()
    }

    /// Zamyka bieżącą serię — po przejściu turnieju albo na żądanie. Zapis jest
    /// trwały, więc przy następnym wejściu ta seria już się nie pojawi.
    private func resolveCurrent() {
        guard let current else { return }
        current.resolvedAt = .now
        try? context.save()
    }

    /// Ściąga z wyprzedzeniem kolejnych pretendentów i początek następnej serii.
    /// Oryginałów nie ma lokalnie, więc bez tego każdy pojedynek zaczyna się od
    /// czekania na iCloud.
    private func prefetchAhead() {
        guard let current else { return }
        var upcoming = Array(current.members.dropFirst(current.challengerIndex).prefix(4))
        if pending.count > 1 { upcoming += pending[1].members.prefix(2) }

        library.prefetch(
            upcoming.compactMap { library.asset(id: $0) },
            targetSize: Self.imageSize
        )
    }
}

/// Ile serii odrzuciłeś jako przypadkowe. Wysoki odsetek znaczy, że czułość
/// jest za wysoka i algorytm skleja rzeczy, które nie mają ze sobą nic wspólnego.
struct RejectionRate: View {
    @Query private var series: [Series]

    var body: some View {
        let judged = series.filter { $0.resolvedAt != nil }
        let rejected = judged.filter(\.wasRejected).count
        if judged.count >= 5 {
            let ratio = Double(rejected) / Double(judged.count)
            Text("· \(rejected)/\(judged.count) rejected")
                .font(.caption)
                .foregroundStyle(ratio > 0.3 ? .orange : .secondary)
                .help(ratio > 0.3 ? "High share — try lowering the sensitivity" : "")
        }
    }
}
