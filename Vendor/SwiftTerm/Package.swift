// swift-tools-version:5.9

// A trimmed fork of SwiftTerm. See README.md for what is patched and why.
//
// Upstream ships four products; this manifest keeps only the library. Dropping
// Termcast and the fuzzer takes swift-argument-parser out of the build graph,
// and dropping the documentation target takes swift-docc-plugin out — neither
// of which MacMoba ever built anything from. The tests are kept, because the
// patch is only defensible while they still pass.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .macOS(.v14),
        .iOS(.v14),
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            // The Metal renderer loads its shaders from the bundle, so this
            // has to survive the trim: without it `setUseMetal` fails at
            // pipeline construction and every terminal silently stays on
            // CoreGraphics.
            resources: [
                .process("Apple/Metal/Shaders.metal")
            ]
        ),
        .testTarget(
            name: "SwiftTermTests",
            dependencies: ["SwiftTerm"],
            path: "Tests/SwiftTermTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
