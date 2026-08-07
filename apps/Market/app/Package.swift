// swift-tools-version:5.9
import PackageDescription

// Market — native macOS SwiftUI hub for the local stock-research pipeline.
// CLT-only build (no Xcode). `swift build` produces an executable; the .app
// bundle is hand-assembled later by the packaging agent.
//
// Zero third-party Swift deps. SQLite reads go through the system libsqlite3
// via the CSQLite C-interop target (module map below). All writes go through
// the Python appctl CLI per CONTRACTS.md.
let package = Package(
    name: "Market",
    platforms: [
        .macOS("26.0") // Liquid Glass (glassEffect) requires macOS 26
    ],
    targets: [
        // C interop shim exposing the system sqlite3 headers to Swift.
        .target(
            name: "CSQLite",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "MarketCore"
        ),
        // The SwiftUI app. The @main entry point lives in MarketApp.swift and
        // is compiled as part of this library-style target so the App lifecycle
        // works under SwiftPM + CLT (parse-as-library semantics).
        .executableTarget(
            name: "Market",
            dependencies: ["CSQLite", "MarketCore"]
        ),
        .executableTarget(
            name: "MarketLogicTests",
            dependencies: ["MarketCore"]
        )
    ]
)
