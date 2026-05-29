// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImportUI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ImportUI",
            targets: ["ImportUI"]
        )
    ],
    dependencies: [
        .package(path: "../LibraryStore"),
        .package(path: "../EPUBKit"),
        .package(path: "../Alignment")
    ],
    targets: [
        .target(
            name: "ImportUI",
            dependencies: [
                .product(name: "LibraryStore", package: "LibraryStore"),
                .product(name: "EPUBKit", package: "EPUBKit")
            ],
            path: "Sources/ImportUI"
        ),
        .testTarget(
            name: "ImportUITests",
            dependencies: [
                "ImportUI",
                .product(name: "Alignment", package: "Alignment")
            ],
            path: "Tests/ImportUITests"
        )
    ]
)
