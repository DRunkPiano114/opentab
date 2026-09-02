import Foundation

public enum RefreshEvent: Sendable {
    case appActivated(AppInfo, FocusGeneration)
    case appLaunched(AppInfo)
    case appTerminated(AppInfo)
    case appHidden(AppInfo)
    case appUnhidden(AppInfo)
    case focusedWindowChanged(AppInfo)
    case titleChanged(AppInfo)
    case periodic
}

public protocol RefreshTrigger: Sendable {
    var events: AsyncStream<RefreshEvent> { get }
}
