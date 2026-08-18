// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMobaCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacMobaCore", targets: ["MacMobaCore"]),
        .executable(name: "MacMoba", targets: ["MacMoba"]),
        .executable(name: "macmoba-cli", targets: ["macmoba-cli"]),
        // NOT named "macmoba": APFS is case-insensitive, so a product named
        // "macmoba" and the app "MacMoba" would overwrite each other in
        // .build/. The bundle step renames the binary to plain `macmoba`.
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // Pinned by revision, not version: RoyalVNC's vendored C targets carry
        // -Wno-* warning suppressions, which SwiftPM classes as "unsafe flags"
        // and refuses in a versioned dependency. The flags are harmless and a
        // revision pin is still reproducible. 60a92e1 is tag 1.0.0.
        .package(url: "https://github.com/royalapplications/royalvnc.git",
                 revision: "60a92e1a60e928b29c16230598efd5a97c134139"),
        // In-app updates (the standard for Developer ID apps outside the App
        // Store): checks an appcast, verifies an EdDSA signature AND the
        // Developer ID signature, then swaps the bundle and relaunches.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "MacMobaCore",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ]
        ),
        // FreeRDP glue. The static libraries come from
        // ./scripts/build-freerdp.sh, which vendors them into Vendor/FreeRDP.
        // unsafeFlags are fine here: this is the root package, and the paths
        // are package-relative.
        .target(
            name: "CMacMobaRDP",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags([
                    "-IVendor/FreeRDP/include/freerdp3",
                    "-IVendor/FreeRDP/include/winpr3",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-LVendor/FreeRDP/lib",
                    "-lfreerdp-client3", "-lfreerdp3", "-lwinpr3",
                    "-lremdesk-common", "-lrdpsnd-common",
                    // OpenSSL by full path to force the static archives:
                    // -lssl would pick Homebrew's dylib, which will not exist
                    // on anyone else's Mac.
                    "/opt/homebrew/opt/openssl@3/lib/libssl.a",
                    "/opt/homebrew/opt/openssl@3/lib/libcrypto.a",
                    "-lz",
                ]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                // FreeRDP detects the keyboard layout through Text Input
                // Services. AppKit pulls Carbon in for the app, but the test
                // binary does not link AppKit, so name it explicitly here.
                .linkedFramework("Carbon"),
                // FreeRDP's rdpsnd channel uses the macOS audio backend. These
                // are system frameworks, so linking them costs nothing at
                // distribution time — unlike compiling the channel out, which
                // makes FreeRDP fail its own addin load during pre-connect.
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        // The control-socket CLI (`macmoba list-tabs` …). Deliberately free of
        // NIO/Core: a plain blocking Unix-socket client, so it builds fast and
        // ships as a tiny helper binary inside the app bundle.
        .executableTarget(
            name: "macmoba-cli",
            path: "Sources/macmoba-cli"
        ),
        .executableTarget(
            name: "MacMoba",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "MacMobaCore",
                "CMacMobaRDP",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ]
        ),
        .testTarget(
            name: "MacMobaCoreTests",
            dependencies: ["MacMobaCore", "CMacMobaRDP",
                           .product(name: "RoyalVNCKit", package: "royalvnc")]
        ),
    ]
)
