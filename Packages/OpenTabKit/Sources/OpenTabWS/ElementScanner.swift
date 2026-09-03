import CoreGraphics
import Foundation

/// The bounded, resumable sweep over AXUIElement ids that turns a CGWindowID
/// the AX enumeration cannot reach into an element (strategy C).
///
/// Every probe is one IPC to the target app, so the sweep is budgeted per
/// call and picks up where it left off on the next one: a window whose id
/// sits high in a long-lived process is found across several refreshes
/// instead of never (H18). A window that a whole cycle of `maxElementID` ids
/// failed to produce is `exhausted` and left alone for `exhaustedRetry`; it is
/// never reported as gone, because a miss says nothing about the window.
///
/// Window elements get low ids (an app creates them before most of its UI),
/// while the rows the WindowServer lists that have no element at all push
/// the cursor high. A window that newly becomes wanted therefore restarts
/// the sweep at 0 instead of waiting for the wrap, and every pending
/// window's exhaustion count restarts with it, so exhaustion always means
/// one full lap.
///
/// Pure with respect to AX: the probes are injected, so the scheduling is
/// unit-tested without a target process.
struct ElementScanner: Sendable {
    struct Configuration: Sendable {
        /// Exclusive upper bound of the id sweep.
        var maxElementID: UInt64 = 32_768
        /// Wall-clock budget of one `scan` call.
        var budget: Duration = .milliseconds(200)
        /// How long an exhausted window id is left alone before another cycle.
        var exhaustedRetry: Duration = .seconds(300)

        init() {}
    }

    /// `windowID(id)`: the CGWindowID the synthesized element belongs to, or
    /// `nil`. `isWindow(id)`: whether that element's role is `AXWindow`. The
    /// second is asked only after the first matched, since `_AXUIElementGetWindow`
    /// answers the containing window's id for every descendant of a window.
    struct Probe {
        let windowID: (UInt64) -> CGWindowID?
        let isWindow: (UInt64) -> Bool
    }

    struct State: Sendable {
        var cursor: UInt64 = 0
        var totalProbed: UInt64 = 0
        /// `totalProbed` when the window became wanted; a window is exhausted
        /// once `maxElementID` probes have passed without a hit.
        var pendingSince: [CGWindowID: UInt64] = [:]
        var exhaustedAt: [CGWindowID: ContinuousClock.Instant] = [:]
        /// Every hit ever made, for the diagnostics histogram.
        var hits: [UInt64] = []
    }

    enum Stop: Equatable, Sendable {
        case allFound
        case nothingWanted
        case budget
        case exhausted
    }

    struct Outcome: Sendable {
        var found: [CGWindowID: UInt64] = [:]
        var exhausted: Set<CGWindowID> = []
        var probed = 0
        var stop: Stop = .nothingWanted
    }

    var configuration = Configuration()

    func scan(wanted: Set<CGWindowID>, state: inout State, deadline: ContinuousClock.Instant,
              now: ContinuousClock.Instant = .now, probe: Probe) -> Outcome {
        var outcome = Outcome()
        let maxID = max(configuration.maxElementID, 1)
        if state.cursor >= maxID { state.cursor = 0 }

        var pending: Set<CGWindowID> = []
        var restart = false
        for wid in wanted {
            if let since = state.exhaustedAt[wid] {
                guard now - since >= configuration.exhaustedRetry else { continue }
                state.exhaustedAt.removeValue(forKey: wid)
            }
            pending.insert(wid)
            if state.pendingSince[wid] == nil { restart = true }
        }
        if restart {
            state.cursor = 0
            for wid in pending { state.pendingSince[wid] = state.totalProbed }
        }
        for wid in state.pendingSince.keys where !wanted.contains(wid) {
            state.pendingSince.removeValue(forKey: wid)
        }
        guard !pending.isEmpty else { return outcome }

        let stopAt = min(deadline, now + configuration.budget)
        while !pending.isEmpty {
            if ContinuousClock.now >= stopAt {
                outcome.stop = .budget
                return outcome
            }
            let id = state.cursor
            state.cursor = (id + 1) % maxID
            state.totalProbed += 1
            outcome.probed += 1

            if let wid = probe.windowID(id), pending.contains(wid), probe.isWindow(id) {
                outcome.found[wid] = id
                pending.remove(wid)
                state.pendingSince.removeValue(forKey: wid)
                state.hits.append(id)
            }
            for wid in pending {
                let since = state.pendingSince[wid] ?? state.totalProbed
                if state.totalProbed - since >= maxID {
                    pending.remove(wid)
                    state.pendingSince.removeValue(forKey: wid)
                    state.exhaustedAt[wid] = now
                    outcome.exhausted.insert(wid)
                }
            }
        }
        outcome.stop = outcome.exhausted.isEmpty ? .allFound : .exhausted
        return outcome
    }
}
