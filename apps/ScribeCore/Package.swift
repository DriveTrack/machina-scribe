// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScribeCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ScribeCore", targets: ["ScribeCore"])
    ],
    targets: [
        .target(name: "ScribeCore"),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"])
    ]
)
