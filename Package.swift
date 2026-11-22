// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WDeviceControllerMac",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "WDeviceControllerMac",
            path: "Sources/WDeviceControllerMac",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
