// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacroSimulator",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "MacroSimulator", targets: ["MacroSimulator"])
    ],
    targets: [
        .executableTarget(
            name: "MacroSimulator",
            dependencies: [],
            path: "Sources/MacroSimulator"
        )
    ]
)
