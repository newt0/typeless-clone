// swift-tools-version:6.0
import PackageDescription

// KoeKit: framework-light logic layer for the Koe voice-input app.
// The macOS .app target (AppKit HUD, CGEventTap, AVAudioEngine, entitlements,
// signing) is added as a thin Xcode wrapper once Xcode is installed and
// depends on this package as a local package. See docs/decisions.md 2026-07-04.
let package = Package(
    name: "KoeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KoeCore", targets: ["KoeCore"]),
    ],
    targets: [
        // Pure-domain logic: no AppKit/AVFoundation. Builds and tests anywhere
        // with the Swift toolchain (no full Xcode required).
        .target(name: "KoeCore"),
        .testTarget(name: "KoeCoreTests", dependencies: ["KoeCore"]),
    ]
)
