// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VocabKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VocabKit",
            targets: ["VocabKit"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VocabKit",
            dependencies: [],
            path: "Sources/VocabKit"
        ),
        .testTarget(
            name: "VocabKitTests",
            dependencies: ["VocabKit"],
            path: "Tests/VocabKitTests"
        )
    ]
)
