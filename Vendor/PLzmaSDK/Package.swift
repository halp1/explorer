// swift-tools-version:5.9
// Vendored PLzmaSDK 1.6.2 (MIT, Oleh Kulykov). Trimmed: tests/bindings removed, unsafeFlags dropped
// so it can be consumed as a local dependency.
import PackageDescription

let package = Package(
    name: "PLzmaSDK",
    platforms: [.macOS(.v13)],
    products: [.library(name: "PLzmaSDK", targets: ["PLzmaSDK"])],
    targets: [
        .target(name: "libplzma", path: "src",
                cSettings: [.define("LIBPLZMA_VERSION_BUILD", to: "1466")],
                cxxSettings: [.define("LIBPLZMA_VERSION_BUILD", to: "1466")]),
        .target(name: "PLzmaSDK", dependencies: ["libplzma"], path: "swift"),
    ],
    cxxLanguageStandard: .cxx14
)
