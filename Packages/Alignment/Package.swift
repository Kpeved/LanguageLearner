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
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMajor(from: "0.9.19")
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.3"
        )
    ],
    targets: [
        .target(
            name: "Alignment",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/Alignment"
        ),
        .testTarget(
            name: "AlignmentTests",
            dependencies: ["Alignment"],
            path: "Tests/AlignmentTests",
            resources: [.process("Resources")]
        )
    ]
)
