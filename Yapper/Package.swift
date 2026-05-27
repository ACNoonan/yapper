// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Yapper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Yapper", targets: ["Yapper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Yapper",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
    ]
)
