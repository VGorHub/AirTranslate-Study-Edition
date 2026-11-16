// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AirTranslate",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AirTranslate", targets: ["AirTranslate"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.1")
    ],
    targets: [
        .target(name: "AirTranslateCore"),
        .executableTarget(
            name: "AirTranslate",
            dependencies: ["AirTranslateCore", .product(name: "Hummingbird", package: "hummingbird")],
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("Speech"),
                .linkedFramework("Translation")
            ]
        ),
        .testTarget(
            name: "AirTranslateCoreTests",
            dependencies: [
                "AirTranslateCore",
                "AirTranslate"
            ]
        )
    ]
)
