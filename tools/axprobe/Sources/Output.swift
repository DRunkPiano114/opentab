import Foundation

/// Writes each command's result twice: machine-readable JSON for diffing and a
/// plain-text summary.
///
/// The summary file matters because this tool must be launched with `open -a`
/// to get its own TCC identity, and an `open`ed app has no terminal to print to.
struct Output {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ name: String, json: JSON, summary: String) throws {
        let stamped = JSON.object([
            "generatedBy": .string("axprobe \(AXProbe.version)"),
            "generatedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "result": json,
        ])
        try stamped.encoded().write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
        let text = summary.hasSuffix("\n") ? summary : summary + "\n"
        try Data(text.utf8).write(to: directory.appendingPathComponent("\(name).txt"), options: .atomic)
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}
