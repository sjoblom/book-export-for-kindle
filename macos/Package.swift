// swift-tools-version:5.9
import PackageDescription

// The native app and its command-line tool. Built with `swift build -c
// release` and assembled into `Kindle Export.app` by scripts/package-app.sh;
// see PLAN.md.
let package = Package(
  name: "KindleExport",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "KindleExport", targets: ["KindleExport"]),
    .executable(name: "kindle-export", targets: ["KindleExportCLI"]),
  ],
  targets: [
    // Everything testable: capture, pipeline, app model. No AppKit entry point.
    .target(name: "KindleExportKit", path: "Sources/KindleExportKit"),
    .executableTarget(
      name: "KindleExport",
      dependencies: ["KindleExportKit"],
      path: "Sources/KindleExport"
    ),
    // The command-line tool, `kindle-export` (the product's name). Shipped
    // inside the app bundle so it shares the app's Amazon sign-in.
    .executableTarget(
      name: "KindleExportCLI",
      dependencies: ["KindleExportKit"],
      path: "Sources/KindleExportCLI"
    ),
    .testTarget(
      name: "KindleExportKitTests",
      dependencies: ["KindleExportKit"],
      path: "Tests/KindleExportKitTests"
    ),
  ]
)
