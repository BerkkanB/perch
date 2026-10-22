// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perch", targets: ["Perch"]),
        .executable(name: "perch-hook", targets: ["PerchHook"]),
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
        // Tiny Foundation-only helper that coding agents' hooks run; it forwards each event to Perch.
        .executableTarget(
            name: "PerchHook",
            path: "Sources/PerchHook"
        ),
        .testTarget(
            name: "PerchTests",
            dependencies: ["Perch"],
            path: "Tests/PerchTests"
        ),
    ]
)
