// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Stillmatter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Stillmatter", targets: ["Stillmatter"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "StillmatterCore",
            dependencies: [],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "StillmatterTranscriptionRuntime",
            dependencies: ["StillmatterCore"]
        ),
        .target(
            name: "StillmatterPresentation",
            dependencies: ["StillmatterCore"]
        ),
        .executableTarget(
            name: "Stillmatter",
            dependencies: ["StillmatterCore", "StillmatterTranscriptionRuntime", "StillmatterPresentation"]
        ),
        .testTarget(
            name: "StillmatterPresentationTests",
            dependencies: ["StillmatterPresentation", "StillmatterCore"]
        ),
        .testTarget(
            name: "StillmatterTests",
            dependencies: ["StillmatterCore", "StillmatterTranscriptionRuntime"]
        )
    ]
)
