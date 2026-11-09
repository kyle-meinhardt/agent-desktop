// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let includePaths = ["build", "source"].flatMap {
    ["-I", root + "/.build/session-library/" + $0 + "/include"]
}

let package = Package(
    name: "agent-desktop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "agent-desktop", targets: ["AgentDesktop"])],
    targets: [
        .target(name: "CVNCBridge", cSettings: [.unsafeFlags(includePaths)]),
        .executableTarget(name: "AgentDesktop", dependencies: ["CVNCBridge"]),
        .testTarget(name: "AgentDesktopTests", dependencies: ["AgentDesktop"])
    ],
    swiftLanguageModes: [.v5]
)
