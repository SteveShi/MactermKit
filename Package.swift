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
            url: "https://github.com/SteveShi/MactermKit/releases/download/v1.0.25/MactermKitCore.xcframework.zip",
            checksum: "00ca7c7bba1eed9b2ba55487b8683af7d22a3347fc6546fdaa76ebfe3295daee"
        )
    ]
)
