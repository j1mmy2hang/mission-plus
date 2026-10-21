// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MissionPlus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MissionPlus",
            path: "Sources/MissionPlus",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
