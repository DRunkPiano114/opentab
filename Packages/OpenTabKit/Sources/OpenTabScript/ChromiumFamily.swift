import Foundation

/// Chrome and Edge ship byte-identical dictionaries, so one provider covers the
/// whole family. Membership is decided by probing the bundle's scripting
/// definition for the Chromium suite code, which also picks up forks nobody
/// enumerated.
public enum ChromiumFamily {
    /// A starting point for onboarding copy only. The probe is what decides.
    public static let knownBundleIDs = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.openai.atlas",
    ]

    static let suiteCode = "code=\"CrSu\""

    public static func isChromium(appURL: URL, fileManager: FileManager = .default) -> Bool {
        guard let definition = scriptingDefinitionURL(appURL: appURL, fileManager: fileManager),
              let text = try? String(contentsOf: definition, encoding: .utf8) else { return false }
        return text.contains(suiteCode)
    }

    private static func scriptingDefinitionURL(appURL: URL, fileManager: FileManager) -> URL? {
        let resources = appURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let declared = Bundle(url: appURL)?
            .object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String
        for name in [declared, "scripting.sdef"].compactMap({ $0 }) {
            let candidate = resources.appending(path: name, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return nil
    }
}
