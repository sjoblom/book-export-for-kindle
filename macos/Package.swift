// swift-tools-version:5.9
import PackageDescription

// The native app. Built with `swift build -c release` and assembled into
// `Kindle Export.app` by scripts/package-app.sh; see PLAN.md.
let package = Package(
  name: "KindleExport",
  platforms: [.macOS(.v13)],
  targets: [
    // Everything testable: capture, pipeline, app model. No AppKit entry point.
    .target(name: "KindleExportKit", path: "Sources/KindleExportKit"),
    .executableTarget(
      name: "KindleExport",
      dependencies: ["KindleExportKit"],
      path: "Sources/KindleExport"
    ),
    .testTarget(
      name: "KindleExportKitTests",
      dependencies: ["KindleExportKit"],
      path: "Tests/KindleExportKitTests"
    ),
  ]
)
