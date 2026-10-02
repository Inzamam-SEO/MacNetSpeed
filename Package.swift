// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "MacNetSpeed",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MacNetSpeed", targets: ["MacNetSpeed"]),
    ],
    targets: [
        .executableTarget(
            name: "MacNetSpeed",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "MacNetSpeedTests",
            dependencies: ["MacNetSpeed"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
