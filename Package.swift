// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SheepitSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "SheepitSDK",
            targets: ["SheepitSDK"]
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
            name: "SheepitSDK",
            dependencies: ["SheepitCrashHandler"],
            path: "Sources/SheepitSDK",
            // Apple requires the privacy manifest to be declared as a
            // resource for SwiftPM to place it in the bundle Xcode reads
            // when it assembles the host app's privacy report.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "SheepitSDKTests",
            dependencies: ["SheepitSDK", "SheepitCrashHandler"],
            path: "Tests/SheepitSDKTests"
        ),
    ]
)
