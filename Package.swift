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
            url: "https://github.com/SteveShi/MactermKit/releases/download/v1.0.24/MactermKitCore.xcframework.zip",
            checksum: "b82fb365aefd5c7f20d46d416368215fcc16fa798a0eb2270e13a13497d0b90c"
        )
    ]
)
