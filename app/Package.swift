// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CantoFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "cantoflow", targets: ["CantoFlowApp"])
    ],
    targets: [
        .executableTarget(
            name: "CantoFlowApp",
            path: "Sources/CantoFlowApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
