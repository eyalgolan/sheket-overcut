// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SheketCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SheketCore", targets: ["SheketCore"]),
    ],
    targets: [
        .target(name: "SheketCore"),
        .testTarget(name: "SheketCoreTests", dependencies: ["SheketCore"]),
    ]
)
