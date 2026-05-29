// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EPUBKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "EPUBKit",
            targets: ["EPUBKit"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMajor(from: "0.9.19")
        )
    ],
    targets: [
        .target(
            name: "EPUBKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/EPUBKit"
        ),
        .testTarget(
            name: "EPUBKitTests",
            dependencies: [
                "EPUBKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Tests/EPUBKitTests"
        )
    ]
)
