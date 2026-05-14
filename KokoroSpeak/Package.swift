// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KokoroSpeak",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KokoroSpeak", targets: ["KokoroSpeak"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "KokoroSpeak",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
    ]
)
