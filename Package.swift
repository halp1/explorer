// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Explorer", targets: ["Explorer"]),
        .executable(name: "ExplorerHelper", targets: ["ExplorerHelper"]),
        .library(name: "ExplorerKit", targets: ["ExplorerKit"]),
    ],
    dependencies: [
        .package(path: "Vendor/PLzmaSDK"),
    ],
    targets: [
        // Declarations for the system libarchive (/usr/lib/libarchive.2.dylib); the SDK ships no headers.
        .target(name: "CArchive", path: "Sources/CArchive", linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "ExplorerHelperProtocol", path: "Sources/ExplorerHelperProtocol"),
        .target(
            name: "ExplorerKit",
            dependencies: ["CArchive", "ExplorerHelperProtocol", .product(name: "PLzmaSDK", package: "PLzmaSDK")],
            path: "Sources/ExplorerKit",
            linkerSettings: [.linkedFramework("CoreServices"), .linkedFramework("NetFS")]
        ),
        .executableTarget(
            name: "Explorer",
            dependencies: ["ExplorerKit"],
            path: "Sources/Explorer",
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("Quartz"), .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("AVKit"), .linkedFramework("VisionKit"), .linkedFramework("ServiceManagement"),
                .linkedFramework("AppIntents"),
                // SwiftPM records the deployment target as the SDK version, which makes macOS run the app
                // in legacy-appearance compatibility mode. Record the real SDK so the window gets the
                // current system design (glass toolbar, floating sidebar) like apps built with Xcode.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "13.0", "-Xlinker", "27.0"]),
            ]
        ),
        .executableTarget(
            name: "ExplorerHelper",
            dependencies: ["ExplorerHelperProtocol"],
            path: "Sources/ExplorerHelper",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Support/Helper-Info.plist"])]
        ),
        .testTarget(name: "ExplorerKitTests", dependencies: ["ExplorerKit"], path: "Tests/ExplorerKitTests"),
    ]
)
