import ApplicationServices
import Foundation

/// Polls the Accessibility grant in both directions. A grant lands without a
/// relaunch, and a revocation while running must be noticed too: reads then
/// fail with `apiDisabled`, and without this the list would only decay.
@MainActor
final class AccessibilityWatch {
    /// Called with the new value on every edge, and once with the first poll.
    var onChange: ((Bool) -> Void)?

    private let isTrusted: () -> Bool
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var lastValue: Bool?

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }, interval: Duration = .seconds(1)) {
        self.isTrusted = isTrusted
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.poll()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func poll() {
        let trusted = isTrusted()
        guard trusted != lastValue else { return }
        lastValue = trusted
        onChange?(trusted)
    }
}
