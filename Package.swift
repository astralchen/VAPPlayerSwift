// swift-tools-version: 6.0
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "VAPPlayer",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "VAPPlayer",
            targets: ["VAPPlayer"]
        )
    ],
    targets: [
        .target(
            name: "VAPPlayer",
            path: "Sources/VAPPlayer",
            resources: [
                .process("Shaders")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "VAPPlayerTests",
            dependencies: ["VAPPlayer"],
            path: "Tests/VAPPlayerTests"
        )
    ]
)
