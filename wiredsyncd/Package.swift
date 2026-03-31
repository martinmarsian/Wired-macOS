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
            resources: [
                .copy("Resources/wired.xml")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(name: "wiredsyncdTests", dependencies: ["wiredsyncd"])
    ]
)
