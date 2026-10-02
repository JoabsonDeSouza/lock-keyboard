// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LockKeyboard",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LockKeyboard", targets: ["LockKeyboard"])],
    targets: [
        .executableTarget(
            name: "LockKeyboard",
            path: "Sources/LockKeyboard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
