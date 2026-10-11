// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AudibleCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "AudibleCore", targets: ["AudibleCore"])],
    targets: [
        .target(name: "AudibleCore"),
        .testTarget(name: "AudibleCoreTests", dependencies: ["AudibleCore"], resources: [.copy("Fixtures")]),
    ]
)
