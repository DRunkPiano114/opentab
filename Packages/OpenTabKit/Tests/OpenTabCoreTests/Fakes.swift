import Foundation
@testable import OpenTabCore

func app(_ name: String, pid: pid_t) -> AppInfo {
    AppInfo(bundleID: "com.example.\(name.lowercased())", pid: pid, localizedName: name)
}

func window(_ id: UInt32, _ app: AppInfo, title: String = "", minimized: Bool = false,
            focused: Bool = false) -> WindowSnapshot {
    WindowSnapshot(key: .cg(id), app: app, title: title.isEmpty ? "\(app.localizedName) \(id)" : title,
                   subrole: "AXStandardWindow", isMinimized: minimized, isFocused: focused)
}
