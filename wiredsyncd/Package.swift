// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "wiredsyncd",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wiredsyncd", targets: ["wiredsyncd"])
    ],
    dependencies: [
        .package(path: "../../WiredSwift")
    ],
    targets: [
        .executableTarget(
            name: "wiredsyncd",
            dependencies: [
                .product(name: "WiredSwift", package: "WiredSwift")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(name: "wiredsyncdTests", dependencies: ["wiredsyncd"])
    ]
)
