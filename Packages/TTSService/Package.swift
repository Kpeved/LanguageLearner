// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TTSService",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TTSService",
            targets: ["TTSService"]
        )
    ],
    targets: [
        .target(
            name: "TTSService",
            path: "Sources/TTSService"
        ),
        .testTarget(
            name: "TTSServiceTests",
            dependencies: ["TTSService"],
            path: "Tests/TTSServiceTests"
        )
    ]
)
