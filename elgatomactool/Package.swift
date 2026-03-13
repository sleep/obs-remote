// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ElgatoCapture",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "elgato-capture",
            path: "Sources/ElgatoCapture",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
            ]
        )
    ]
)
