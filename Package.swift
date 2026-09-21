// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesktopUse",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "JevCore", targets: ["JevCore"]),
        .executable(name: "desktop-use", targets: ["DesktopUse"])
    ],
    targets: [
        .target(name: "JevCore"),
        .executableTarget(name: "DesktopUse", dependencies: ["JevCore"])
    ]
)
