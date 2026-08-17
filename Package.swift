// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Chordsmith",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Chordsmith",
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
                .linkedLibrary("sqlite3"),
                .linkedFramework("NaturalLanguage")
            ]
        ),
        .target(
            name: "Device",
            dependencies: ["Library"]
        ),
        .target(
            name: "Engine",
            dependencies: ["Library"],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                "Library",
                "Device",
                "Engine",
                "KeyboardShortcuts"
            ],
            linkerSettings: [
                .linkedFramework("ServiceManagement")
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
