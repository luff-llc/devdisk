// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "devdisk",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "devdisk", targets: ["devdisk"]),
        .library(name: "DevDiskCore", targets: ["DevDiskCore"]),
    ],
    targets: [
        .target(name: "DevDiskCore"),
        .executableTarget(name: "devdisk", dependencies: ["DevDiskCore"]),
        .testTarget(name: "DevDiskCoreTests", dependencies: ["DevDiskCore"]),
    ]
)
