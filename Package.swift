// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kopi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kopi", targets: ["Kopi"]),
    ],
    targets: [
        // Storage and clip logic. No AppKit, so it is unit-testable with `swift test`.
        .target(
            name: "KopiCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The menu-bar app itself.
        .executableTarget(
            name: "Kopi",
            dependencies: ["KopiCore"]
        ),
        .testTarget(
            name: "KopiCoreTests",
            dependencies: ["KopiCore"]
        ),
        // AppKit-side tests (pasteboard round trips on private pasteboards, shortcut names).
        .testTarget(
            name: "KopiTests",
            dependencies: ["Kopi", "KopiCore"]
        ),
    ]
)
