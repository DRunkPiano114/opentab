import AppKit
import ApplicationServices
import OpenTabCore
import os

/// Refresh events without private API (L15): `NSWorkspace` app-lifecycle
/// notifications, one lightweight `AXObserver` on the frontmost app only,
/// and a periodic tick as the safety net.
@MainActor
public final class AXRefreshTrigger: RefreshTrigger {
    private enum Lifecycle: Sendable {
        case activated, launched, terminated, hidden, unhidden
    }

    nonisolated public let events: AsyncStream<RefreshEvent>

    private nonisolated let continuation: AsyncStream<RefreshEvent>.Continuation
    private nonisolated let periodicInterval: Duration
    private nonisolated let log = Log.make("refresh")

    private var tokens: [NSObjectProtocol] = []
    private var periodicTask: Task<Void, Never>?
    private var attachRetry: Task<Void, Never>?
    private var generation = FocusGeneration.initial
    private var frontmost: FrontmostObserver?

    public nonisolated init(periodicInterval: Duration = .seconds(5)) {
        self.periodicInterval = periodicInterval
        let (stream, continuation) = AsyncStream<RefreshEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    /// Safe to call after the Accessibility grant lands and again after `stop()`.
    public func start() {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        let subscriptions: [(Notification.Name, Lifecycle)] = [
            (NSWorkspace.didActivateApplicationNotification, .activated),
            (NSWorkspace.didLaunchApplicationNotification, .launched),
            (NSWorkspace.didTerminateApplicationNotification, .terminated),
            (NSWorkspace.didHideApplicationNotification, .hidden),
            (NSWorkspace.didUnhideApplicationNotification, .unhidden),
        ]
        for (name, lifecycle) in subscriptions {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = Self.appInfo(from: notification) else { return }
                MainActor.assumeIsolated { self?.handle(lifecycle, app: app) }
            })
        }

        periodicTask = Task { [continuation, periodicInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: periodicInterval) } catch { return }
                continuation.yield(.periodic)
            }
        }

        if let app = NSWorkspace.shared.frontmostApplication.flatMap(Self.appInfo) {
            attachObserver(to: app)
        }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
        periodicTask?.cancel()
        periodicTask = nil
        attachRetry?.cancel()
        attachRetry = nil
        frontmost?.detach()
        frontmost = nil
    }

    private nonisolated static func appInfo(from notification: Notification) -> AppInfo? {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return nil
        }
        return appInfo(app)
    }

    private nonisolated static func appInfo(_ app: NSRunningApplication) -> AppInfo? {
        guard app.processIdentifier != getpid() else { return nil }
        return AppInfo(bundleID: app.bundleIdentifier ?? "", pid: app.processIdentifier,
                       localizedName: app.localizedName ?? "")
    }

    private func handle(_ lifecycle: Lifecycle, app: AppInfo) {
        switch lifecycle {
        case .activated:
            generation = generation.next()
            continuation.yield(.appActivated(app, generation))
            attachObserver(to: app)
        case .launched:
            continuation.yield(.appLaunched(app))
        case .terminated:
            if frontmost?.app.pid == app.pid {
                frontmost?.detach()
                frontmost = nil
            }
            continuation.yield(.appTerminated(app))
        case .hidden:
            continuation.yield(.appHidden(app))
        case .unhidden:
            continuation.yield(.appUnhidden(app))
        }
    }

    fileprivate func observerFired(_ notification: String, app: AppInfo) {
        switch notification {
        case kAXFocusedWindowChangedNotification:
            continuation.yield(.focusedWindowChanged(app))
        case kAXTitleChangedNotification:
            continuation.yield(.titleChanged(app))
        default:
            break
        }
    }

    /// Moves the single observer to `app`. `AXObserverCreate` can fail right
    /// after an app launches, so one retry is scheduled a second later.
    private func attachObserver(to app: AppInfo) {
        attachRetry?.cancel()
        attachRetry = nil
        if frontmost?.app.pid == app.pid { return }
        frontmost?.detach()
        frontmost = nil

        if let observer = FrontmostObserver(app: app, trigger: self) {
            frontmost = observer
            return
        }
        attachRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.frontmost == nil else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid else { return }
            self.frontmost = FrontmostObserver(app: app, trigger: self)
        }
    }
}

/// The one `AXObserver` on the frontmost app. Its refcon is a raw pointer to
/// this object, so the run loop source is removed before the object can go
/// away.
@MainActor
private final class FrontmostObserver {
    let app: AppInfo
    weak var trigger: AXRefreshTrigger?

    private let observer: AXObserver
    private let element: AXUIElement
    private static let notifications = [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification]

    init?(app: AppInfo, trigger: AXRefreshTrigger) {
        guard app.pid != getpid() else { return nil }
        var created: AXObserver?
        let error = AXObserverCreate(app.pid, frontmostObserverCallback, &created)
        guard error == .success, let created else {
            trigger.observerCreateFailed(app: app, error: error)
            return nil
        }
        self.app = app
        self.trigger = trigger
        self.observer = created
        self.element = AXUIElementCreateApplication(app.pid)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.notifications {
            let error = AXObserverAddNotification(observer, element, notification as CFString, refcon)
            if error != .success {
                trigger.observerAddFailed(app: app, error: error)
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    isolated deinit {
        detach()
    }

    func detach() {
        for notification in Self.notifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

extension AXRefreshTrigger {
    fileprivate func observerCreateFailed(app: AppInfo, error: AXError) {
        log.debug("AXObserverCreate failed pid=\(app.pid, privacy: .public) error=\(axErrorName(error), privacy: .public)")
    }

    fileprivate func observerAddFailed(app: AppInfo, error: AXError) {
        log.debug("AXObserverAddNotification failed pid=\(app.pid, privacy: .public) error=\(axErrorName(error), privacy: .public)")
    }
}

/// Declared as a top-level `func`: a stored closure at file scope would be
/// main-actor-isolated and unusable as a C function pointer.
private func frontmostObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                       _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let context = Unmanaged<FrontmostObserver>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // The run loop source lives on the main run loop, so this runs on the main thread.
    MainActor.assumeIsolated {
        context.trigger?.observerFired(name, app: context.app)
    }
}
