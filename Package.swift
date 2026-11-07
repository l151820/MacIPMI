// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacIPMI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacIPMI", targets: ["MacIPMI"]),
        .executable(name: "ipmi-cli", targets: ["ipmi-cli"]),
        .library(name: "IPMIKit", targets: ["IPMIKit"]),
    ],
    targets: [
        .target(name: "IPMIKit"),
        .executableTarget(name: "MacIPMI", dependencies: ["IPMIKit"]),
        .executableTarget(name: "ipmi-cli", dependencies: ["IPMIKit"]),
        .executableTarget(name: "ipmikit-selftest", dependencies: ["IPMIKit"], path: "Tests/IPMIKitTests"),
    ]
)
