import AppKit
import OpenTabCore

/// Watches for other copies of OpenTab running in this login session.
///
/// Registering the same global chord from two processes succeeds in both, and
/// Carbon then delivers every press to both, so two panels open on top of each
/// other. Neither copy notices anything wrong on its own.
///
/// A process that shares our bundle id is invisible to every push mechanism
/// macOS offers: it triggers neither the workspace launch and termination
/// notifications nor a key-value observation of the running-application list,
/// however reliably both fire for any other application. Rescanning on a
/// timer is therefore the only way it is ever found, and the cost of one pass
/// over the list is negligible. The observation is kept because it does fire
/// for a copy whose bundle id differs from ours, which is then reported at
/// once instead of at the next tick.
@MainActor
final class InstanceWatch {
    /// Another running copy, as much of it as the warning needs to name it.
    struct OtherInstance: Equatable {
        let pid: pid_t
        /// Nil for a process that reports a bundle id but no bundle path.
        let path: String?
    }

    /// One entry of the running-application list, reduced to the fields the
    /// verdict reads.
    struct Candidate: Equatable {
        let pid: pid_t
        let bundleIdentifier: String?
        let bundleURL: URL?
        let isTerminated: Bool
    }

    /// Debug and release builds carry different bundle ids and both are the
    /// switcher, so the whole family counts.
    nonisolated static let bundleIDPrefix = "im.opentab.app"

    /// How long a copy can be running, or gone, before it is noticed.
    private static let pollInterval = Duration.seconds(5)

    /// Sorted by pid, so the same set of copies always yields the same list.
    private(set) var others: [OtherInstance] = []
    var onChange: (([OtherInstance]) -> Void)?

    private let log = Log.make("instance")
    private var observation: NSKeyValueObservation?
    private var poll: Task<Void, Never>?

    /// Identity is decided by bundle id alone: the display name is
    /// localized, and the two builds differ in it on purpose. Matching whole
    /// id components keeps the command-line probes, which share the
    /// `im.opentab` prefix, out of the result.
    ///
    /// A copy that has exited keeps its place in the running-application list
    /// for a while, marked terminated; counting it would leave the warning up
    /// after the conflict is gone.
    nonisolated static func others(among candidates: [Candidate], ownPID: pid_t) -> [OtherInstance] {
        candidates
            .filter { candidate in
                guard !candidate.isTerminated, candidate.pid != ownPID,
                      let id = candidate.bundleIdentifier else { return false }
                return id == bundleIDPrefix || id.hasPrefix(bundleIDPrefix + ".")
            }
            .map { OtherInstance(pid: $0.pid, path: $0.bundleURL?.path) }
            .sorted { $0.pid < $1.pid }
    }

    func start() {
        stop()
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            // KVO reports on whichever thread changed the array.
            Task { @MainActor in self?.rescan() }
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.rescan()
            }
        }
        rescan()
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        poll?.cancel()
        poll = nil
    }

    private func rescan() {
        let candidates = NSWorkspace.shared.runningApplications.map {
            Candidate(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                      bundleURL: $0.bundleURL, isTerminated: $0.isTerminated)
        }
        let found = Self.others(among: candidates, ownPID: getpid())
        guard found != others else { return }
        others = found
        // Both directions are logged: the list only ever changes here, so
        // this is the whole record of what the warning was told to say.
        if found.isEmpty {
            log.notice("other copies gone")
        }
        for other in found {
            log.error("""
                another copy is running pid=\(other.pid, privacy: .public) \
                path=\(other.path ?? "unknown", privacy: .public)
                """)
        }
        onChange?(found)
    }
}
