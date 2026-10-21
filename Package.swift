// swift-tools-version: 6.0
import PackageDescription

// Every layer is a SwiftPM target so it builds and tests on macOS without Xcode, and so
// MeasurementCore can't accidentally import UI or AVFoundation. macOS exists only for tests.
let package = Package(
    name: "Moth",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "MeasurementCore", targets: ["MeasurementCore"]),
        .library(name: "MothCapture", targets: ["MothCapture"]),
        .library(name: "MothPersistence", targets: ["MothPersistence"]),
        .library(name: "MothUI", targets: ["MothUI"])
    ],
    targets: [
        .target(
            name: "MeasurementCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MothCapture",
            dependencies: ["MeasurementCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Separate from MothUI so the store and migrations test without AVFoundation or SwiftUI.
        .target(
            name: "MothPersistence",
            dependencies: ["MeasurementCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MothUI",
            dependencies: ["MeasurementCore", "MothCapture", "MothPersistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeasurementCoreTests",
            dependencies: ["MeasurementCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MothCaptureTests",
            dependencies: ["MothCapture", "MeasurementCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MothPersistenceTests",
            dependencies: ["MothPersistence", "MeasurementCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
