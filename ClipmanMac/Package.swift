// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipmanMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ClipmanCore", targets: ["ClipmanCore"]),
        .executable(name: "Clipman", targets: ["Clipman"])
    ],
    dependencies: [],
    targets: [
        .systemLibrary(name: "CZlib"),
        .systemLibrary(name: "CCommonCrypto"),
        .target(
            name: "ClipmanCore",
            dependencies: [
                "CZlib",
                "CCommonCrypto"
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("z")
            ]
        ),
        .executableTarget(
            name: "Clipman",
            dependencies: [
                "ClipmanCore"
            ],
            exclude: [
                "Resources"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "ClipmanCodecSmoke",
            dependencies: [
                "ClipmanCore"
            ]
        ),
        .executableTarget(
            name: "ClipmanSyncSmoke",
            dependencies: [
                "ClipmanCore"
            ]
        ),
        .executableTarget(
            name: "ClipmanFileHistorySmoke",
            dependencies: [
                "ClipmanCore"
            ]
        )
    ]
)
