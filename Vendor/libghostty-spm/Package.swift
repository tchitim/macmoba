// swift-tools-version: 6.0

// A trimmed fork of Lakr233/libghostty-spm. See README.md for the one patch.
//
// Upstream ships four libraries; this keeps GhosttyKit (the C API) and
// GhosttyTerminal (the views), which is all MacMoba's experimental pane uses.
// GhosttyTheme and ShellCraftKit are dropped.
//
// The libghostty binary itself is NOT vendored: it stays the upstream
// XCFramework release, fetched and checksum-verified by SwiftPM exactly as
// before. Only the Swift wrapper is forked, because only the Swift wrapper
// needed changing.

import PackageDescription

let package = Package(
    name: "GhosttyKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v15),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", from: "2.2.0"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            path: "Sources/GhosttyTerminal",
            resources: [
                .copy("Resources/Ghostty"),
                .copy("Resources/terminfo"),
            ]
        ),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/Lakr233/libghostty-spm/releases/download/upstream.1.3.1-2/GhosttyKit.xcframework.zip",
            checksum: "512fa0fc973b47839263b43f6dcdc5cffea12452e41ed7117f04f0a3ef213eb4"
        ),
    ]
)
