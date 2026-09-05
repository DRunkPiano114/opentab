import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// Puts up the system Accessibility prompt.
    let promptForAccessibility: () -> Void
    let openAccessibilitySettings: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                if model.step != .welcome {
                    Button("Back", action: model.back)
                }
                if model.isLast {
                    Button("Done", action: finish)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue", action: model.advance)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAdvance)
                }
            }
        }
        .padding(24)
        .frame(width: 460, height: 380)
    }

    private var title: String {
        switch model.step {
        case .welcome: "Welcome to OpenTab"
        case .what: "One list for every window"
        case .accessibility: "Allow Accessibility"
        case .shortcuts: "Choose your shortcut"
        case .done: "You're set"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            Text("""
                OpenTab lives in the menu bar and puts every open window — and every browser tab — one \
                keystroke away. This takes about a minute.
                """)
        case .what:
            VStack(alignment: .leading, spacing: 10) {
                bullet("Hold the shortcut and tap to move down the list; let go to switch.")
                bullet("Press Return to start typing. Search matches app names, window titles and pinyin.")
                bullet("Press \u{2192} on a browser window to see its tabs.")
            }
        case .accessibility:
            VStack(alignment: .leading, spacing: 12) {
                Text("""
                    macOS requires this to let OpenTab see the windows other apps have open, and to switch \
                    to the one you pick. Nothing leaves your Mac.
                    """)
                HStack(spacing: 12) {
                    if model.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(model.hasPromptedForAccessibility ? "Open System Settings\u{2026}" : "Allow\u{2026}") {
                            if model.hasPromptedForAccessibility {
                                openAccessibilitySettings()
                            } else {
                                promptForAccessibility()
                            }
                        }
                        Text("Waiting\u{2026} this window continues on its own.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .shortcuts:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(OnboardingModel.ShortcutChoice.allCases, id: \.self) { option($0) }
                Toggle("Open OpenTab at login", isOn: $model.opensAtLogin)
                if model.shortcutChoice == .cmdTab {
                    Text("Opening at login means a crash cannot leave you without an app switcher.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Change these any time in Settings \u{203A} Shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: 10) {
                Text("Press \(model.mainHotKey.displayString) to try it.")
                Text("""
                    OpenTab is in the menu bar. Private and incognito windows stay out of the list, and \
                    nothing is sent anywhere, unless you change that in Settings \u{203A} Privacy.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
            Text(text)
        }
    }

    /// One row of the choice. Built out of a plain button rather than a
    /// radio-group picker, because macOS does not reliably honour `.disabled`
    /// on a single option of a picker and the Command-Tab row has to be
    /// disabled on its own.
    private func option(_ choice: OnboardingModel.ShortcutChoice) -> some View {
        Button {
            model.shortcutChoice = choice
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.shortcutChoice == choice ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.shortcutChoice == choice ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    chip(choice.main)
                    Text(caption(for: choice))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(choice == .cmdTab && !model.takeoverAvailable)
    }

    private func caption(for choice: OnboardingModel.ShortcutChoice) -> String {
        switch choice {
        case .cmdTab:
            model.takeoverAvailable
                ? "\u{2318}\u{2009}Tab replaces the system app switcher while OpenTab runs and comes back when it quits."
                : "\u{2318}\u{2009}Tab is not available on this Mac, so OpenTab is using \u{2325}\u{2009}Tab."
        case .optionTab:
            "Leaves the system app switcher alone."
        }
    }

    private func chip(_ binding: HotKeyBinding) -> some View {
        Text(binding.displayString)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
    }
}
