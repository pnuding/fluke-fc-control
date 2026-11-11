// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "FlukeFCControl",
    platforms: [.macOS(.v26)],
    targets: [
        // Pure protocol layer (reading decoding, names, UUIDs). No CoreBluetooth /
        // SwiftUI, so it can be unit-tested headlessly.
        .target(
            name: "FlukeCore",
            path: "Sources/FlukeCore"
        ),
        .executableTarget(
            name: "FlukeFCControl",
            dependencies: ["FlukeCore"],
            path: "Sources/FlukeFCControl"
        ),
        .testTarget(
            name: "FlukeCoreTests",
            dependencies: ["FlukeCore"],
            path: "Tests/FlukeCoreTests"
        ),
    ]
)
