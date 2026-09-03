// swift-tools-version: 6.2
import PackageDescription

// Every product is a static library: a dynamic framework inside the app bundle
// would carry its own signature and break the stable designated requirement.
let package = Package(
    name: "OpenTabKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenTabCore", type: .static, targets: ["OpenTabCore"]),
        .library(name: "OpenTabAX", type: .static, targets: ["OpenTabAX"]),
        .library(name: "OpenTabScript", type: .static, targets: ["OpenTabScript"]),
        .library(name: "OpenTabWS", type: .static, targets: ["OpenTabWS"]),
    ],
    targets: [
        // Pure logic. Imports Foundation and os only, so it is testable with no
        // GUI and no TCC grant.
        .target(name: "OpenTabCore"),
        .target(name: "OpenTabAX", dependencies: ["OpenTabCore"]),
        .target(name: "OpenTabScript", dependencies: ["OpenTabCore"]),
        .target(name: "OpenTabWS", dependencies: ["OpenTabCore", "OpenTabAX"]),
        .testTarget(name: "OpenTabCoreTests", dependencies: ["OpenTabCore"]),
        .testTarget(name: "OpenTabScriptTests", dependencies: ["OpenTabScript"]),
        .testTarget(name: "OpenTabWSTests", dependencies: ["OpenTabWS"]),
    ],
    swiftLanguageModes: [.v6]
)
