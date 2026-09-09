// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SheepitKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "SheepitKit",
            targets: ["SheepitKit"]
        ),
    ],
    targets: [
        .target(
            name: "SheepitCrashHandler",
            path: "Sources/SheepitCrashHandler",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "SheepitKit",
            dependencies: ["SheepitCrashHandler"],
            path: "Sources/SheepitKit",
            // Apple requires the privacy manifest to be declared as a
            // resource for SwiftPM to place it in the bundle Xcode reads
            // when it assembles the host app's privacy report.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "SheepitKitTests",
            dependencies: ["SheepitKit", "SheepitCrashHandler"],
            path: "Tests/SheepitKitTests"
        ),
    ]
)
