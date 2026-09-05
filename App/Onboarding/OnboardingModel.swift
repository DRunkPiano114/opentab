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

    /// The chord the switcher opens on, as the first run offers it.
    enum ShortcutChoice: CaseIterable {
        case cmdTab, optionTab

        var main: HotKeyBinding { self == .cmdTab ? .cmdTab : .optionTab }
        var reverse: HotKeyBinding { self == .cmdTab ? .cmdShiftTab : .optionShiftTab }
    }

    private(set) var step: Step = .welcome
    var accessibilityGranted = false
    /// Set once the system prompt has been put up, so the step can stop
    /// offering to do it again.
    private(set) var hasPromptedForAccessibility = false

    var shortcutChoice: ShortcutChoice = .cmdTab {
        didSet { opensAtLogin = shortcutChoice == .cmdTab }
    }

    /// Ticked while Cmd-Tab is selected, because a crash then leaves the
    /// system switcher off until OpenTab runs again. The user may untick it.
    var opensAtLogin = true

    /// False on a Mac without the window-server write; Cmd-Tab is then not
    /// offered at all.
    var takeoverAvailable = true {
        didSet { if !takeoverAvailable { shortcutChoice = .optionTab } }
    }

    var mainHotKey: HotKeyBinding { shortcutChoice.main }
    var reverseHotKey: HotKeyBinding { shortcutChoice.reverse }

    /// Called with the selection whenever the shortcuts step is confirmed, and
    /// once more from the window closing if the step was reached but never
    /// confirmed. The controller writes it into the settings store.
    var onShortcutsChosen: ((ShortcutChoice, Bool) -> Void)?

    /// Whether the user has seen the choice. Closing the window before that
    /// applies nothing, so nobody gets a login item they were never shown.
    private(set) var hasReachedShortcuts = false

    /// The Accessibility step is the one gate: nothing after it works without
    /// the grant, so it does not offer a way past.
    var canAdvance: Bool {
        step != .accessibility || accessibilityGranted
    }

    var isLast: Bool { step == .done }

    func advance() {
        guard canAdvance, let next = Step(rawValue: step.rawValue + 1) else { return }
        if step == .shortcuts { onShortcutsChosen?(shortcutChoice, opensAtLogin) }
        step = next
        if step == .shortcuts { hasReachedShortcuts = true }
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Applies what the user was shown when the flow ends somewhere other than
    /// the Continue button. Every write it triggers is idempotent, so
    /// confirming the step and then closing the window is harmless.
    func applySelectionIfReached() {
        guard hasReachedShortcuts else { return }
        onShortcutsChosen?(shortcutChoice, opensAtLogin)
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
