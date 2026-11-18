// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pulsar",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Pulsar",
            path: "Sources/Pulsar",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
