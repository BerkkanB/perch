// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perch", targets: ["Perch"]),
    ],
    targets: [
        .executableTarget(
            name: "Perch",
            path: "Sources/Perch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "PerchTests",
            dependencies: ["Perch"],
            path: "Tests/PerchTests"
        ),
    ]
)
