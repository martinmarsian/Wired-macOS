// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "wiredsyncd",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wiredsyncd", targets: ["wiredsyncd"])
    ],
    targets: [
        .executableTarget(
            name: "wiredsyncd",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(name: "wiredsyncdTests", dependencies: ["wiredsyncd"])
    ]
)
