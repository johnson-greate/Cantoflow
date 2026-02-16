// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CantoFlowLightUI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "cantoflow-light-ui", targets: ["CantoFlowLightUI"])
    ],
    targets: [
        .executableTarget(
            name: "CantoFlowLightUI"
        )
    ]
)
