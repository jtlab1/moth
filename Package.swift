// swift-tools-version: 6.0
import PackageDescription

// Every layer is a SwiftPM target so MeasurementCore can't accidentally import UI or AVFoundation.
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
        // Separate from MothUI so the store and migrations don't depend on AVFoundation or SwiftUI.
        .target(
            name: "MothPersistence",
            dependencies: ["MeasurementCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MothUI",
            dependencies: ["MeasurementCore", "MothCapture", "MothPersistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
