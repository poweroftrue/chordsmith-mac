// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Charaworder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Charaworder",
            targets: ["App"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.3.0")
    ],
    targets: [
        .target(
            name: "Library",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "Device",
            dependencies: ["Library"]
        ),
        .target(
            name: "Engine",
            dependencies: ["Library"]
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                "Library",
                "Device",
                "Engine",
                "KeyboardShortcuts"
            ]
        ),
        .testTarget(
            name: "LibraryTests",
            dependencies: ["Library"]
        ),
        .testTarget(
            name: "DeviceTests",
            dependencies: ["Device", "Library"]
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine", "Library"]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["App", "Device", "Library"]
        )
    ]
)
