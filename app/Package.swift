// swift-tools-version: 5.9
import PackageDescription

// ======================================================================
// JOTTBAR SWIFT PACKAGE
// ======================================================================
// Builds a plain executable. The .app bundle around it is assembled by
// ../install.sh so that Xcode Command Line Tools alone are enough to
// build -- no full Xcode project required.
let package = Package(
    name: "JottBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "JottBar",
            path: "Sources/JottBar"
        )
    ]
)
