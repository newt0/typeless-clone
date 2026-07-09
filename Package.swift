// swift-tools-version:6.0
import PackageDescription

// KoeKit: framework-light logic layer for the Koe voice-input app.
// - KoeCore   : pure domain logic, no third-party deps (builds/tests anywhere).
// - KoeStorage: GRDB(SQLite)-backed stores; isolates the DB dependency so
//               KoeCore stays dependency-free.
// The macOS .app target (AppKit HUD, CGEventTap, AVAudioEngine, entitlements,
// signing) is a thin Xcode wrapper (project.yml). See docs/decisions.md.
let package = Package(
    name: "KoeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KoeCore", targets: ["KoeCore"]),
        .library(name: "KoeStorage", targets: ["KoeStorage"]),
        .library(name: "KoeProviders", targets: ["KoeProviders"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "KoeCore"),
        .testTarget(name: "KoeCoreTests", dependencies: ["KoeCore"]),
        .target(
            name: "KoeStorage",
            dependencies: [
                "KoeCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "KoeStorageTests", dependencies: ["KoeStorage"]),
        // STT/LLM provider adapters (URLSession); no third-party deps.
        .target(name: "KoeProviders", dependencies: ["KoeCore"]),
        .testTarget(name: "KoeProvidersTests", dependencies: ["KoeProviders"]),
        // S3 golden set: case model + deterministic checks + the bundled v1
        // set (durable asset; the Phase 1 prompt-regression gate).
        .target(
            name: "KoeGolden",
            dependencies: ["KoeCore"],
            resources: [.copy("Resources/golden-set-v1.json")]
        ),
        .testTarget(name: "KoeGoldenTests", dependencies: ["KoeGolden"]),
        // S3-T2 harness CLI: runs the set against a configured LLMClient
        // (keys required at run time, not build time).
        .executableTarget(
            name: "golden-harness",
            dependencies: ["KoeGolden", "KoeCore", "KoeProviders"]
        ),
    ]
)
