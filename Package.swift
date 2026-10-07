// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Portree",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "PortreeCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Portree",
            dependencies: ["PortreeCore"]
        ),
        .testTarget(
            name: "PortreeCoreTests",
            dependencies: ["PortreeCore"]
        ),
    ]
)
