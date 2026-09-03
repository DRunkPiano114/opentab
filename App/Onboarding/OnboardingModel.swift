import Foundation
import Observation

/// The first-run flow. The Accessibility step advances itself the moment the
/// grant lands: macOS does not require a relaunch for it, and asking the user
/// to quit and reopen would be inventing a restriction that is not there.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome, what, accessibility, shortcuts, done
    }

    private(set) var step: Step = .welcome
    var accessibilityGranted = false
    /// Set once the system prompt has been put up, so the step can stop
    /// offering to do it again.
    private(set) var hasPromptedForAccessibility = false

    var mainHotKey = HotKeyBinding.mainDefault
    var reverseHotKey = HotKeyBinding.reverseDefault
    var searchHotKey = HotKeyBinding.searchDefault

    /// The Accessibility step is the one gate: nothing after it works without
    /// the grant, so it does not offer a way past.
    var canAdvance: Bool {
        step != .accessibility || accessibilityGranted
    }

    var isLast: Bool { step == .done }

    func advance() {
        guard canAdvance, let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    func markPrompted() { hasPromptedForAccessibility = true }

    /// The grant landing while the Accessibility step is up moves the flow on
    /// by itself.
    func accessibilityChanged(_ granted: Bool) {
        accessibilityGranted = granted
        guard granted, step == .accessibility else { return }
        advance()
    }
}
