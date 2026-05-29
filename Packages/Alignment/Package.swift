// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Alignment",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "Alignment", targets: ["Alignment"])
    ],
    targets: [
        .target(name: "Alignment", path: "Sources/Alignment"),
        .testTarget(name: "AlignmentTests", dependencies: ["Alignment"], path: "Tests/AlignmentTests")
    ]
)
