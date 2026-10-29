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
            url: "https://github.com/SteveShi/MactermKit/releases/download/v1.0.34/MactermKitCore.xcframework.zip",
            checksum: "c84f01969e9c379433dbfae53c8a38052c5eeb2f6257b58685adadfd9e06a333"
        )
    ]
)
