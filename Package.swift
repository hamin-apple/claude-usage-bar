// swift-tools-version:5.9
import Foundation
import PackageDescription

// The checks target shares UsageAPI.swift and LaunchOptions.swift through symlinks.
// npm does not pack symlinks, so the npm package ships without that directory and
// the target is only declared when its sources are present.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasChecks = FileManager.default.fileExists(
    atPath: root.appendingPathComponent("Sources/ClaudeUsageBarChecks/UsageAPI.swift").path)

var targets: [Target] = [
    .executableTarget(name: "ClaudeUsageBar", path: "Sources/ClaudeUsageBar")
]
if hasChecks {
    targets.append(.executableTarget(name: "ClaudeUsageBarChecks", path: "Sources/ClaudeUsageBarChecks"))
}

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v13)],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
