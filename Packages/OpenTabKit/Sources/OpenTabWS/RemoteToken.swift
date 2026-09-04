import Foundation

/// The 20-byte remote token `_AXUIElementCreateWithRemoteToken` accepts, read
/// off the arm64 disassembly of HIServices on macOS 26.6.2 and cross-checked
/// against tokens dumped from live windows:
///
///     0x00  4B  pid (little-endian)
///     0x04  4B  0
///     0x08  4B  0x636f636f "coco"
///     0x0c  8B  AXUIElementID
///
/// The first 12 bytes are a per-process constant; only the element id varies
/// per window. A live window's token is the preferred source of the prefix;
/// an app that reports no AX windows at all - a fullscreen app reports none -
/// gets the synthesized one. A fullscreen Safari with no live AX window was
/// reached from a purely synthesized prefix.
struct RemoteToken: Equatable, Sendable {
    static let length = 20
    static let prefixLength = 12
    static let magic: UInt32 = 0x636f_636f

    let bytes: [UInt8]

    /// `nil` unless the bytes have the documented length and magic.
    init?(bytes: [UInt8]) {
        guard bytes.count == Self.length, Self.load(UInt32.self, from: bytes, at: 8) == Self.magic else { return nil }
        self.bytes = bytes
    }

    init(prefix: [UInt8], elementID: UInt64) {
        precondition(prefix.count == Self.prefixLength)
        var bytes = prefix
        withUnsafeBytes(of: elementID.littleEndian) { bytes.append(contentsOf: $0) }
        self.bytes = bytes
    }

    static func synthesizedPrefix(pid: pid_t) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: UInt32(bitPattern: Int32(pid)).littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: [0, 0, 0, 0])
        withUnsafeBytes(of: magic.littleEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }

    var pid: pid_t { pid_t(Int32(bitPattern: Self.load(UInt32.self, from: bytes, at: 0))) }
    var elementID: UInt64 { Self.load(UInt64.self, from: bytes, at: Self.prefixLength) }
    var prefix: [UInt8] { Array(bytes.prefix(Self.prefixLength)) }

    private static func load<T: FixedWidthInteger>(_: T.Type, from bytes: [UInt8], at offset: Int) -> T {
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { destination in
            for i in 0..<MemoryLayout<T>.size { destination[i] = bytes[offset + i] }
        }
        return T(littleEndian: value)
    }
}
