// swift-tools-version: 6.0
// Voixful dictation app — a macOS push-to-talk dictation front-end built on the
// Voixful core API (the root package, referenced by local path).
//
// Two products:
//   • VoixfulKit  — the reusable, UI-agnostic core (model catalog, download/store,
//                   settings, and the dictation session that drives VoixfulAnalyzer).
//                   Kept platform-portable so a future iOS app can reuse it.
//   • VoixfulApp  — the macOS SwiftUI executable: sidebar (Settings + Models),
//                   floating HUD, menu-bar item, global push-to-talk + paste.

import PackageDescription

let package = Package(
    name: "VoixfulApp",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "VoixfulKit", targets: ["VoixfulKit"]),
        .executable(name: "VoixfulDictation", targets: ["VoixfulApp"]),
    ],
    dependencies: [
        // The Voixful core lives one directory up. Local path keeps the app in
        // lock-step with the engine it dogfoods.
        .package(path: ".."),
    ],
    targets: [
        // MARK: Reusable core (portable across macOS / iOS)
        .target(
            name: "VoixfulKit",
            dependencies: [
                .product(name: "VoixfulSpeech", package: "Voixful"),
                .product(name: "VoixfulEngine", package: "Voixful"),
                .product(name: "VoixfulNemotronStreaming", package: "Voixful"),
                .product(name: "VoixfulParakeetTDT", package: "Voixful"),
                .product(name: "VoixfulCohereTranscribe", package: "Voixful"),
                .product(name: "VoixfulGraniteNAR", package: "Voixful"),
                .product(name: "VoixfulCanaryQwen", package: "Voixful"),
                .product(name: "VoixfulFullContext", package: "Voixful"),
            ]
        ),

        // MARK: macOS SwiftUI app
        .executableTarget(
            name: "VoixfulApp",
            dependencies: ["VoixfulKit"],
            // Embed an Info.plist so macOS TCC grants REAL microphone audio (a
            // bare SwiftPM binary is otherwise fed silence) and the process runs
            // as a menu-bar accessory. Same linker trick the root CLI uses.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/VoixfulApp/Info.plist",
                ])
            ]
        ),

        // MARK: Kit unit tests (headless smoke coverage)
        .testTarget(
            name: "VoixfulKitTests",
            dependencies: ["VoixfulKit"]
        ),
    ]
)
