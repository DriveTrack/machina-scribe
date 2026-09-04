// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScribeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ScribeCore", targets: ["ScribeCore"])
    ],
    targets: [
        .target(name: "ScribeCore"),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"])
    ]
)
