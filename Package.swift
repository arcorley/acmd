// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ACMD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ACMD", targets: ["ACMD"])
    ],
    targets: [
        .target(
            name: "ACMDCore",
            path: "Sources/ACMDCore"
        ),
        .executableTarget(
            name: "ACMD",
            dependencies: [
                "ACMDCore"
            ],
            path: "Sources/ACMD"
        ),
        .testTarget(
            name: "ACMDCoreTests",
            dependencies: ["ACMDCore"],
            path: "Tests/ACMDCoreTests"
        ),
        .testTarget(
            name: "ACMDTests",
            dependencies: ["ACMD"],
            path: "Tests/ACMDTests"
        )
    ]
)
