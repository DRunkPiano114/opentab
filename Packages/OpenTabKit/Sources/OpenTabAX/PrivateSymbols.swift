import ApplicationServices
import CoreGraphics
import Foundation

/// `AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *)` — the only
/// element-to-window-number bridge that exists.
typealias AXGetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// Private symbols are resolved with `dlsym` and `nil` when absent (L10);
/// nothing here is linked directly.
enum PrivateSymbols {
    static let getWindow: AXGetWindowFunction? = resolve("_AXUIElementGetWindow")

    private static func resolve<T>(_ name: String) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
