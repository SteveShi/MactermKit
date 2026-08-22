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
                "GhosttyKit",
                .product(name: "MSDisplayLink", package: "MSDisplayLink")
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            url: "https://github.com/SteveShi/libghostty-swift/releases/download/v1.0.12/GhosttyKit.xcframework.zip",
            checksum: "bbefef52e73b1724bf40c3cdb618c4ff7449b7eacd1c46b2f9757ccd730ff2f8"
        )
    ]
)
