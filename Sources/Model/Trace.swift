import Foundation
import os

/// Czasy etapów, które mogą stać na głównym wątku, do logu systemowego.
/// Czyta się je bez zaglądania do aplikacji:
/// `log show --last 5m --predicate 'subsystem == "pl.3210.lightbrary"'`
enum Trace {
    private static let log = Logger(subsystem: "pl.3210.lightbrary", category: "timing")

    @discardableResult
    static func measure<T>(_ label: StaticString, _ work: () throws -> T) rethrows -> T {
        let started = ContinuousClock.now
        defer { report(label, since: started) }
        return try work()
    }

    static func measure<T>(_ label: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let started = ContinuousClock.now
        defer { report(label, since: started) }
        return try await work()
    }

    /// Zacięcie głównego wątku — żeby zestawić je z etapami po godzinie.
    static func stall(_ ms: Double) {
        log.notice("STALL \(ms, format: .fixed(precision: 0), privacy: .public) ms")
    }

    /// Etap zmierzony gdzie indziej (np. zegar synchronizacji).
    static func note(_ label: String, seconds: Double) {
        log.notice("\(label, privacy: .public) \(seconds * 1000, format: .fixed(precision: 0), privacy: .public) ms main=\(Thread.isMainThread, privacy: .public)")
    }

    /// Zwykłe zdarzenie z opisem — np. co zrobił klawisz w ocenianiu.
    static func event(_ text: String) {
        log.notice("EVENT \(text, privacy: .public)")
    }

    private static func report(_ label: StaticString, since started: ContinuousClock.Instant) {
        let span = (ContinuousClock.now - started).components
        let ms = Double(span.seconds) * 1000 + Double(span.attoseconds) / 1e15
        log.notice("\(label, privacy: .public) \(ms, format: .fixed(precision: 0), privacy: .public) ms main=\(Thread.isMainThread, privacy: .public)")
    }
}
