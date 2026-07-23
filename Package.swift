// swift-tools-version: 6.0
// PrivoVoice dictation app — a macOS push-to-talk dictation front-end built on the
// Voixful core API (the root package, referenced by local path).
//
// Two-process architecture (Handy-style, native): the UI process owns the menu
// bar, hotkey, mic, HUD, and paste; a separate resident engine process loads the
// Core AI model and transcribes, so a model-runtime crash can't take the UI down.
// They talk over a length-prefixed stdio protocol.
//
// Targets:
//   • PrivoVoiceKit           — reusable, UI-agnostic core (catalog, store, settings,
//                            DictationController + the DictationEngine protocol with
//                            an in-process impl). Portable to iOS.
//   • PrivoVoiceIPC           — the tiny wire protocol shared by both processes.
//   • PrivoVoiceApp           — the macOS SwiftUI UI process (spawns the engine).
//   • PrivoVoiceHelper  — the resident engine process (the sidecar).

import PackageDescription

let package = Package(
    name: "PrivoVoice",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "PrivoVoiceKit", targets: ["PrivoVoiceKit"]),
        .executable(name: "PrivoVoice", targets: ["PrivoVoiceApp"]),
        // Built as a product so it's always compiled; the UI process spawns it.
        .executable(name: "PrivoVoiceHelper", targets: ["PrivoVoiceHelper"]),
    ],
    dependencies: [
        // The Voixful engine package lives alongside this one (../voixful). Local path keeps the app in
        // lock-step with the engine it dogfoods.
        .package(path: "../voixful"),
    ],
    targets: [
        // MARK: Cross-process wire protocol (Foundation-only, both processes share)
        .target(name: "PrivoVoiceIPC"),

        // MARK: Reusable core (portable across macOS / iOS)
        .target(
            name: "PrivoVoiceKit",
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

        // MARK: Engine process (the sidecar) — loads the model, transcribes
        .executableTarget(
            name: "PrivoVoiceHelper",
            dependencies: ["PrivoVoiceKit", "PrivoVoiceIPC"]
        ),

        // MARK: macOS SwiftUI app (UI process)
        .executableTarget(
            name: "PrivoVoiceApp",
            dependencies: ["PrivoVoiceKit", "PrivoVoiceIPC"],
            // Embed an Info.plist so macOS TCC grants REAL microphone audio (a
            // bare SwiftPM binary is otherwise fed silence) and the process runs
            // as a menu-bar accessory. Same linker trick the root CLI uses.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PrivoVoiceApp/Info.plist",
                ])
            ]
        ),

        // MARK: Kit unit tests (headless smoke coverage)
        .testTarget(
            name: "PrivoVoiceKitTests",
            dependencies: ["PrivoVoiceKit", "PrivoVoiceIPC"]
        ),
    ]
)
