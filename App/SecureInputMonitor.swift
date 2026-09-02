import Carbon
import Foundation

/// Polls `IsSecureEventInputEnabled()`. There is no notification for it, and a
/// password field anywhere on the system flips it on.
@MainActor
final class SecureInputMonitor {
    /// Called with the new value on every change, including the first poll.
    var onChange: ((Bool) -> Void)?

    private let interval: Duration
    private var task: Task<Void, Never>?
    private var lastValue: Bool?

    init(interval: Duration = .seconds(1)) {
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
        let active = IsSecureEventInputEnabled()
        guard active != lastValue else { return }
        lastValue = active
        onChange?(active)
    }
}
