// swift-tools-version: 5.9
import PackageDescription

let coreLinkerSettings: [LinkerSetting] = [
    .linkedFramework("AVFoundation"),
    .linkedFramework("CoreMedia"),
    .linkedFramework("CoreVideo"),
    .linkedFramework("VideoToolbox"),
    .linkedFramework("CoreImage"),
    .linkedFramework("ImageIO"),
]

let package = Package(
    name: "ElgatoCapture",
    platforms: [.macOS(.v13)],
    targets: [
        // Shared capture engine library
        .target(
            name: "CaptureCore",
            path: "Sources/CaptureCore",
            linkerSettings: coreLinkerSettings
        ),
        // CLI version
        .executableTarget(
            name: "elgato-capture",
            dependencies: ["CaptureCore"],
            path: "Sources/ElgatoCapture",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        // GUI version (SwiftUI)
        .executableTarget(
            name: "elgato-capture-gui",
            dependencies: ["CaptureCore"],
            path: "Sources/ElgatoCaptureGUI",
            resources: [
                .copy("WebRoot"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
