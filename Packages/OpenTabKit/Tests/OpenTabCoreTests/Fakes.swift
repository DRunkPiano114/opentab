import Foundation
import os
@testable import OpenTabCore

func app(_ name: String, pid: pid_t) -> AppInfo {
    AppInfo(bundleID: "com.example.\(name.lowercased())", pid: pid, localizedName: name)
}

func window(_ id: UInt32, _ app: AppInfo, title: String = "", minimized: Bool = false,
            focused: Bool = false) -> WindowSnapshot {
    WindowSnapshot(key: .cg(id), app: app, title: title.isEmpty ? "\(app.localizedName) \(id)" : title,
                   subrole: "AXStandardWindow", isMinimized: minimized, isFocused: focused)
}

/// Snapshots per app, mutable from tests, plus optional failure injection.
final class FakeWindowSource: WindowSource, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State {
        var windows: [AppKey: [WindowSnapshot]] = [:]
        var failing: Set<AppKey> = []
        var delays: [AppKey: Duration] = [:]
        var snapshotCount = 0
    }

    func set(_ snapshots: [WindowSnapshot], for app: AppInfo) {
        lock.withLock { $0.windows[app.key] = snapshots }
    }

    func fail(_ app: AppInfo, _ failing: Bool = true) {
        lock.withLock { if failing { $0.failing.insert(app.key) } else { $0.failing.remove(app.key) } }
    }

    func delay(_ app: AppInfo, _ duration: Duration) {
        lock.withLock { $0.delays[app.key] = duration }
    }

    var snapshotCount: Int { lock.withLock { $0.snapshotCount } }

    func snapshot(of app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [WindowSnapshot] {
        let (result, failing, delay) = lock.withLock { state -> ([WindowSnapshot], Bool, Duration?) in
            state.snapshotCount += 1
            return (state.windows[app.key] ?? [], state.failing.contains(app.key), state.delays[app.key])
        }
        if let delay { try await Task.sleep(for: delay) }
        if failing { throw Failure() }
        return result
    }
}

final class FakeAppDirectory: AppDirectory, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<([AppInfo], Set<AppKey>)>(initialState: ([], []))

    func set(apps: [AppInfo]) { lock.withLock { $0.0 = apps } }
    func setHidden(_ app: AppInfo, _ hidden: Bool) {
        lock.withLock { if hidden { $0.1.insert(app.key) } else { $0.1.remove(app.key) } }
    }

    func runningApps() -> [AppInfo] { lock.withLock { $0.0 } }
    func isHidden(_ app: AppInfo) -> Bool { lock.withLock { $0.1.contains(app.key) } }
}

/// Events are pushed by the test and delivered through a real `AsyncStream`.
final class FakeRefreshTrigger: RefreshTrigger, @unchecked Sendable {
    let events: AsyncStream<RefreshEvent>
    private let continuation: AsyncStream<RefreshEvent>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<RefreshEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    func send(_ event: RefreshEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
}
