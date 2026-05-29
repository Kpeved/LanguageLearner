// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReaderUI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ReaderUI",
            targets: ["ReaderUI"]
        )
    ],
    dependencies: [
        .package(path: "../LibraryStore"),
        .package(path: "../Alignment"),
        .package(path: "../TTSService")
    ],
    targets: [
        .target(
            name: "ReaderUI",
            dependencies: [
                .product(name: "LibraryStore", package: "LibraryStore"),
                .product(name: "Alignment", package: "Alignment"),
                .product(name: "TTSService", package: "TTSService")
            ],
            path: "Sources/ReaderUI"
        ),
        .testTarget(
            name: "ReaderUITests",
            dependencies: ["ReaderUI"],
            path: "Tests/ReaderUITests"
        )
    ]
)
