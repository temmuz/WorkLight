// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Worklight",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Worklight", targets: ["Worklight"]),
        .executable(name: "WorklightChecks", targets: ["WorklightChecks"])
    ],
    targets: [
        .target(name: "WorklightCore"),
        .executableTarget(name: "Worklight", dependencies: ["WorklightCore"]),
        .executableTarget(name: "WorklightChecks", dependencies: ["WorklightCore"], path: "Checks")
    ]
)
