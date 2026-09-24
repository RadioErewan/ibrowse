import Foundation
import SwiftUI

/// Mierzy responsywność głównego wątku podczas przewijania siatki.
///
/// Timer chodzi na głównym runloopie w trybie `.common` — to jest istotne,
/// bo w trakcie scrolla runloop wchodzi w tryb śledzenia i zwykły timer
/// przestałby się odpalać, pokazując fałszywe zero. Kiedy główny wątek miele
/// miniatury, tiki przychodzą rzadziej i licznik spada razem z płynnością.
///
/// To nie zastępuje Instruments, ale odpowiada na jedyne pytanie, które nas
/// interesuje: czy SwiftUI wyrabia na skali całego archiwum.
@MainActor
final class PerfMonitor: ObservableObject {
    @Published private(set) var ticksPerSecond: Double = 0
    @Published private(set) var worstStallMS: Double = 0
    @Published private(set) var memoryMB: Double = 0
    @Published private(set) var thumbsLoaded = 0
    @Published private(set) var inFlight = 0

    private var timer: Timer?
    private var ticks = 0
    private var windowStart = CACurrentMediaTime()
    private var lastTick = CACurrentMediaTime()

    /// Odpytujemy szybciej niż odświeża się ekran, żeby złapać też krótkie
    /// zacięcia, które przy 60 Hz zniknęłyby w zaokrągleniu.
    private static let interval = 1.0 / 120.0

    init() {
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    private func tick() {
        let now = CACurrentMediaTime()

        // Największa przerwa między tikami w oknie pomiarowym. Średnia potrafi
        // wyglądać zdrowo mimo pojedynczych zacięć — a to właśnie one bolą.
        let gap = (now - lastTick) * 1000
        if gap > worstStallMS { worstStallMS = gap }
        if gap > 100 { Trace.stall(gap) }
        lastTick = now

        ticks += 1
        let elapsed = now - windowStart
        guard elapsed >= 0.5 else { return }

        ticksPerSecond = Double(ticks) / elapsed
        ticks = 0
        windowStart = now
        memoryMB = Self.residentMemoryMB()
    }

    func didStartLoad() { inFlight += 1 }

    func didFinishLoad() {
        inFlight = max(0, inFlight - 1)
        thumbsLoaded += 1
    }

    func resetStall() { worstStallMS = 0 }

    /// Pamięć rezydentna procesu — pokazuje, czy cache miniatur trzyma się
    /// w ryzach przy przewijaniu przez tysiące pozycji.
    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }
}

/// Pasek z odczytami. Świadomie surowy i zawsze na wierzchu — to przyrząd
/// pomiarowy, nie element produktu.
struct PerfOverlay: View {
    @ObservedObject var monitor: PerfMonitor
    let total: Int

    /// 120 tików/s to płynność bez zarzutu, 60 to wciąż dobrze,
    /// poniżej 30 scroll jest odczuwalnie szarpany.
    private var health: Color {
        switch monitor.ticksPerSecond {
        case 90...: .green
        case 45...: .yellow
        default: .red
        }
    }

    private var stallHealth: Color {
        switch monitor.worstStallMS {
        case ..<20: .green
        case ..<50: .yellow
        default: .red
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            reading("tik/s", String(format: "%.0f", monitor.ticksPerSecond), health)
            reading("max hitch", String(format: "%.0f ms", monitor.worstStallMS), stallHealth)
            reading("memory", String(format: "%.0f MB", monitor.memoryMB), .primary)
            reading("thumbnails", "\(monitor.thumbsLoaded)", .primary)
            reading("in flight", "\(monitor.inFlight)", .primary)
            reading("photos", "\(total)", .secondary)

            Button("reset") { monitor.resetStall() }
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
    }

    private func reading(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color).fontWeight(.semibold)
        }
    }
}
