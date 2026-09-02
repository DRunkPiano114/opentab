import AppKit
import ApplicationServices
import Foundation

/// Accessibility tree probe for OpenTab.
///
/// Ships as a signed .app bundle purely so that it has a stable TCC identity:
/// a bare executable run from a granted terminal inherits that terminal's
/// Accessibility grant and reports a false positive.
///
/// Everything runs synchronously on the main thread. There is no concurrency to
/// get wrong, and each AX read is bounded by the global messaging timeout.
@main
enum AXProbe {
    static let version = "0.1.0"
    static let bundleIdentifierFallback = "com.paulwu.opentab.axprobe"

    static func main() {
        // Registers the process with LaunchServices so `open -W` can observe it
        // exiting. LSUIElement keeps it out of the Dock.
        NSApplication.shared.setActivationPolicy(.accessory)

        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            exit(try dispatch(arguments))
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("axprobe: \(error.description)\n\n".utf8))
            FileHandle.standardError.write(Data((CLI.usage + "\n").utf8))
            writeFailure(arguments: arguments, message: error.description)
            exit(64)
        } catch {
            FileHandle.standardError.write(Data("axprobe: \(error)\n".utf8))
            writeFailure(arguments: arguments, message: "\(error)")
            exit(70)
        }
    }

    private static func dispatch(_ arguments: [String]) throws -> Int32 {
        guard !arguments.isEmpty, !arguments.allSatisfy({ $0.hasPrefix("-psn_") }) else {
            print(CLI.usage)
            return 64
        }

        let cli = try CLI(arguments: arguments)
        if cli.flag("help") || cli.command == "help" {
            print(CLI.usage)
            return 0
        }

        let output = try Output(directory: outputDirectory(cli.string("out")))

        // Set once, on the system-wide element, before any other AX call: a
        // timeout set on an application element is not inherited by its windows.
        let timeout = try cli.double("timeout", default: 0.25)
        _ = AXRead.setGlobalTimeout(Float(timeout))

        switch cli.command {
        case "doctor": return try CommandDoctor.run(output: output)
        case "list": return try CommandList.run(output: output)
        case "dump": return try CommandDump.run(cli: cli, output: output)
        case "tabs": return try CommandTabs.run(cli: cli, output: output)
        case "spaces": return try CommandSpaces.run(cli: cli, output: output)
        case "selftest": return try CommandSelfTest.run(output: output)
        default: throw CLIError("unknown command '\(cli.command)'")
        }
    }

    static func outputDirectory(_ override: String?) -> URL {
        if let override {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? bundleIdentifierFallback)
    }

    /// A failure has to reach a file too: launched via `open`, this process has
    /// no terminal, so stderr goes nowhere the caller can read.
    private static func writeFailure(arguments: [String], message: String) {
        let outIndex = arguments.firstIndex(of: "--out").map { $0 + 1 }
        let override = outIndex.flatMap { $0 < arguments.count ? arguments[$0] : nil }
        guard let output = try? Output(directory: outputDirectory(override)) else { return }
        try? output.write("error",
                          json: .object(["command": .strings(arguments), "error": .string(message)]),
                          summary: "axprobe failed: \(message)")
    }
}
