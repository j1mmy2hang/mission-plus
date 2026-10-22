// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MissionPlus",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "MissionPlus",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MissionPlus",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                // Sparkle.framework is embedded in the app's Contents/Frameworks (see build.sh).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
