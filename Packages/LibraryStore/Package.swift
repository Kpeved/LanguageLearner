// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LibraryStore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LibraryStore",
            targets: ["LibraryStore"]
        )
    ],
    dependencies: [
        .package(path: "../EPUBKit"),
        .package(path: "../Alignment")
    ],
    targets: [
        .target(
            name: "LibraryStore",
            dependencies: [
                .product(name: "EPUBKit", package: "EPUBKit"),
                .product(name: "Alignment", package: "Alignment")
            ],
            path: "Sources/LibraryStore"
        ),
        .testTarget(
            name: "LibraryStoreTests",
            dependencies: ["LibraryStore"],
            path: "Tests/LibraryStoreTests"
        )
    ]
)
