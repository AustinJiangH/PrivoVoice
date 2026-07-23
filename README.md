# Voixful for macOS

A push-to-talk dictation app for Apple Silicon, built entirely on the Voixful
core API (the package one directory up). Hold a key, speak, release — the
transcript is pasted wherever your cursor is. Everything runs on-device via
Apple Core AI; no audio leaves your Mac.

> Code here is Apache-2.0 (repo root `LICENSE`). Model **weights** carry their
> upstream licenses — see [`../MODEL_CARD.md`](../MODEL_CARD.md).

## What it does

- **Push-to-talk dictation.** Hold the configured key (default: `fn`), speak,
  release. The finished transcript is pasted at the cursor, optionally copied to
  the clipboard.
- **Floating HUD.** A small top-center overlay shows an amplitude meter while
  listening and a shimmer while transcribing — animation only, no window focus.
- **Menu-bar app.** A status item reflects the global state (idle / listening /
  transcribing) and opens Settings or quits.
- **Model management.** Browse every Voixful checkpoint, filter by language,
  download (or import a local `.aimodel`), select one, and delete the rest.

## Architecture — a reusable core

The package splits into two products so the non-UI logic can be reused (e.g. by
a future iOS app):

### Two processes (Handy-style, native)

Transcription runs in a **separate process** from the UI, so a crash or hang in
the (beta) Core AI model runtime can't take the app down. This is the native
equivalent of how [Handy](https://github.com/cjpais/Handy) isolates its Rust
core from its UI — here it's a spawned Swift "sidecar" talking over a
length-prefixed stdio protocol (no XPC service / Xcode entitlements needed).

```
┌────────────────────────┐   stdio frames    ┌──────────────────────────┐
│ VoixfulDictation (UI)  │  begin / audio →  │ VoixfulEngineHelper      │
│  menu bar · hotkey ·   │  ← partial/final  │  loads the .aimodel and  │
│  mic · HUD · paste     │                   │  drives VoixfulAnalyzer  │
└────────────────────────┘                   └──────────────────────────┘
        holds mic + Accessibility                 no TCC permissions —
                                                   just audio in, text out
```

The mic and Accessibility permissions stay in the UI process; the sidecar only
receives audio frames and returns text, so it needs no TCC grants. If it dies,
the UI respawns it on the next dictation.

| Target | Platform | Contents |
|---|---|---|
| **`VoixfulKit`** | portable (macOS / iOS) | Catalog, download/store, settings, `AppState`, `AudioCapture`, `DictationController`, and the `DictationEngine` protocol + `InProcessDictationEngine`. No AppKit/SwiftUI. |
| **`VoixfulIPC`** | portable | The tiny wire protocol (message enums + framing) shared by both processes. |
| **`VoixfulApp`** | macOS | SwiftUI sidebar (Settings + Models), HUD, menu-bar item, hotkey, paste, and `HelperProcessDictationEngine` (spawns the sidecar). |
| **`VoixfulEngineHelper`** | macOS | The resident engine process. Runs an `InProcessDictationEngine` behind the IPC protocol. |

The split hides behind the `DictationEngine` protocol: macOS injects the
sidecar-backed engine; a future **iOS** app (which can't spawn processes) reuses
`VoixfulKit` with the `InProcessDictationEngine` instead — no other change.

```
app/
├── Package.swift
├── Sources/
│   ├── VoixfulIPC/                # Protocol.swift, Frame.swift  (shared)
│   ├── VoixfulKit/               # reusable core
│   │   ├── Catalog/ Settings/ Store/ Support/
│   │   └── Session/{AppState,AudioCapture,TranscriberFactory,
│   │               DictationEngine,InProcessDictationEngine,DictationController}.swift
│   ├── VoixfulEngineHelper/      # main.swift  (the sidecar)
│   └── VoixfulApp/               # macOS SwiftUI UI process
│       ├── App/ Engine/ Hotkey/ Paste/ HUD/ MenuBar/ UI/
│       └── Info.plist
├── scripts/make-app.sh           # bundle both binaries into Voixful.app
└── Tests/VoixfulKitTests/        # catalog/settings + IPC framing + real sidecar handshake
```

## Build & run

```bash
cd app
swift build                 # compiles all four targets against the core
swift test                  # headless smoke: catalog, settings, IPC, sidecar handshake
swift run VoixfulDictation  # dev run — UI spawns the sidecar from .build/
```

For a real, double-clickable GUI app (menu-bar item, stable permissions):

```bash
./scripts/setup-signing.sh  # ONCE: create a stable self-signed identity so TCC
                            # grants (Input Monitoring/Accessibility) persist
./scripts/make-app.sh       # → build/Voixful.app  (bundles both binaries, signs)
open build/Voixful.app
```

> **Run `setup-signing.sh` once.** Without it, `make-app.sh` falls back to ad-hoc
> signing, which changes the app's identity every build — so macOS forgets your
> Input Monitoring / Accessibility grants and push-to-talk silently stops working
> after each rebuild. The self-signed "Voixful Dev" identity keeps one stable
> signature (needs Homebrew `openssl@3`; the first `codesign` shows one keychain
> prompt — click **Always Allow**). Local dev only; use a Developer ID to
> distribute.

The first launch prompts for two permissions — grant both, then **relaunch**:

1. **Microphone** — to capture your speech.
2. **Accessibility** (and **Input Monitoring** if separately prompted) — for the
   global push-to-talk hotkey and paste-at-cursor.

> `swift run` works for development (the UI finds the sidecar next to itself in
> `.build/`). `make-app.sh` ad-hoc signs for local use; for distribution, swap in
> a Developer ID identity and notarize the bundle.

## Models

Selecting a model in the **Models** tab downloads its `.aimodel` into the storage
location (default `~/Library/Voixful/Models/`, changeable in Settings). Until the
converted assets are published to Hugging Face, use **Import…** on a card to
install a locally-converted asset (see [`../convert/`](../convert)); download
surfaces a clear "not yet published" message otherwise.

Each card shows what the model is good for: native streaming vs. re-transcribe,
speed and accuracy ratings, supported languages, on-disk size, leaderboard WER,
and the weights license.

## Notes & limitations

- The push-to-talk tap is **listen-only** (it never swallows the key), so a
  *printable* trigger key would also type. Prefer the default `fn`, an F-key, or
  a modifier chord.
- Native streaming (live words) is Nemotron only; every other backend
  re-transcribes the growing utterance for live partials (see the root README's
  support matrix).
