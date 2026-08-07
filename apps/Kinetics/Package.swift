// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kinetics",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Kinetics", targets: ["Kinetics"]),
        .executable(name: "KineticsLoginLauncher", targets: ["KineticsLoginLauncher"])
    ],
    targets: [
        .target(
            name: "KineticsCore",
            path: "Sources/KineticsCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "Kinetics",
            dependencies: ["KineticsCore"],
            path: "Sources/Kinetics"
        ),
        .executableTarget(
            name: "KineticsLoginLauncher",
            path: "Sources/KineticsLoginLauncher",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        )
    ]
)
