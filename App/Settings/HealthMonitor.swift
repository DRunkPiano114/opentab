import Darwin
import Foundation
import OpenTabCore

/// The long-run memory read-out, which exists because footprint and behaviour
/// past a few hours of uptime were never measured. It samples the process
/// footprint and the size of the index on a timer and writes one line per
/// sample to the unified log under the `health` category, so a multi-day
/// observation is a single `log show` afterwards rather than something
/// somebody has to sit and watch:
///
///     /usr/bin/log show --last 72h --style compact \
///       --predicate 'subsystem == "im.opentab.app" AND category == "health"'
///
/// The subsystem is the bundle id, so a Debug build logs under
/// `im.opentab.app.dev` instead.
///
/// The same snapshot is shown live in the settings window.
@MainActor
final class HealthMonitor {
    struct Snapshot: Equatable, Sendable {
        /// `phys_footprint`, the number Activity Monitor shows as Memory.
        var footprintBytes: UInt64
        var peakFootprintBytes: UInt64
        var entryCount: Int
        var uptime: Duration

        var text: String {
            "\(HealthMonitor.megabytes(footprintBytes)) MB now, "
                + "\(HealthMonitor.megabytes(peakFootprintBytes)) MB peak \u{00B7} "
                + "running \(HealthMonitor.uptimeText(uptime))"
        }
    }

    /// How big the index is right now. Supplied by the owner.
    var entryCount: () -> Int = { 0 }

    private let interval: Duration
    private let started = ContinuousClock.now
    private var peak: UInt64 = 0
    private var task: Task<Void, Never>?
    private let log = Log.make("health")

    init(interval: Duration = .seconds(300)) {
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.record()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func snapshot() -> Snapshot {
        let footprint = Self.footprintBytes()
        peak = max(peak, footprint)
        return Snapshot(footprintBytes: footprint, peakFootprintBytes: peak,
                        entryCount: entryCount(), uptime: started.duration(to: .now))
    }

    private func record() {
        let snapshot = snapshot()
        log.notice("""
            footprintBytes=\(snapshot.footprintBytes, privacy: .public) \
            peakBytes=\(snapshot.peakFootprintBytes, privacy: .public) \
            rows=\(snapshot.entryCount, privacy: .public) \
            uptimeSeconds=\(snapshot.uptime.components.seconds, privacy: .public)
            """)
    }

    /// `phys_footprint` from `TASK_VM_INFO`; zero when the call fails, which
    /// is reported as such rather than guessed at.
    nonisolated static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    nonisolated static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    nonisolated static func uptimeText(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        return seconds < 3_600 ? "\(seconds / 60) min" : String(format: "%.1f h", Double(seconds) / 3_600)
    }
}
