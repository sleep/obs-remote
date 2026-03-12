// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OBSRemote",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "obs-remote-server", targets: ["OBSRemoteServer"]),
        .library(name: "OBSRemoteShared", targets: ["OBSRemoteShared"]),
    ],
    targets: [
        .target(name: "OBSRemoteShared"),
        .executableTarget(
            name: "OBSRemoteServer",
            dependencies: ["OBSRemoteShared"]
        ),
    ]
)
