// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MactermKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "MactermKit",
            targets: ["MactermKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", from: "2.1.0")
    ],
    targets: [
        .target(
            name: "MactermKit",
            dependencies: [
                "MactermKitCore",
                .product(name: "MSDisplayLink", package: "MSDisplayLink")
            ]
        ),
        .binaryTarget(
            name: "MactermKitCore",
            url: "https://github.com/SteveShi/MactermKit/releases/download/v1.0.15/MactermKitCore.xcframework.zip",
            checksum: "47e9aa1947c2bed8bfa705e6de6af7343696e04a45c23ec1f5611e4c3c920552"
        )
    ]
)
