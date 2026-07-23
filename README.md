# PrivoVoice for macOS

A push-to-talk dictation app for Apple Silicon, built entirely on the Voixful
core API (the package one directory up). Hold a key, speak, release — the
transcript is pasted wherever your cursor is. Everything runs on-device via
Apple Core AI; no audio leaves your Mac.

> Code here is Apache-2.0 (repo root `LICENSE`). Model **weights** carry their
> upstream licenses — see [`../MODEL_CARD.md`](../MODEL_CARD.md).

## What it does

- **Push-to-talk dictation.** Hold the configured shortcut (default: `fn`), speak,
  release. The finished transcript is pasted at the cursor, optionally copied to
  the clipboard.
- **Floating HUD.** A small top-center overlay shows an amplitude meter while
  listening and a shimmer while transcribing — animation only, no window focus.
- **Menu-bar app.** A status item reflects the global state (idle / listening /
  transcribing) and opens Settings or quits.
- **Model management.** Browse every model checkpoint, filter by language,
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
│ PrivoVoice (UI)  │  begin / audio →  │ PrivoVoiceHelper      │
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
| **`PrivoVoiceKit`** | portable (macOS / iOS) | Catalog, download/store, settings, `AppState`, `AudioCapture`, `DictationController`, and the `DictationEngine` protocol + `InProcessDictationEngine`. No AppKit/SwiftUI. |
| **`PrivoVoiceIPC`** | portable | The tiny wire protocol (message enums + framing) shared by both processes. |
| **`PrivoVoiceApp`** | macOS | SwiftUI sidebar (Settings + Models), HUD, menu-bar item, hotkey, paste, and `HelperProcessDictationEngine` (spawns the sidecar). |
| **`PrivoVoiceHelper`** | macOS | The resident engine process. Runs an `InProcessDictationEngine` behind the IPC protocol. |

The split hides behind the `DictationEngine` protocol: macOS injects the
sidecar-backed engine; a future **iOS** app (which can't spawn processes) reuses
`PrivoVoiceKit` with the `InProcessDictationEngine` instead — no other change.

```
app/
├── Package.swift
├── Sources/
│   ├── PrivoVoiceIPC/                # Protocol.swift, Frame.swift  (shared)
│   ├── PrivoVoiceKit/               # reusable core
│   │   ├── Catalog/ Settings/ Store/ Support/
│   │   └── Session/{AppState,AudioCapture,TranscriberFactory,
│   │               DictationEngine,InProcessDictationEngine,DictationController}.swift
│   ├── PrivoVoiceHelper/      # main.swift  (the sidecar)
│   └── PrivoVoiceApp/               # macOS SwiftUI UI process
│       ├── App/ Engine/ Hotkey/ Paste/ HUD/ MenuBar/ UI/
│       └── Info.plist
├── scripts/make-app.sh           # bundle both binaries into PrivoVoice.app
└── Tests/PrivoVoiceKitTests/        # catalog/settings + IPC framing + real sidecar handshake
```

## Build & run

```bash
cd app
swift build                 # compiles all four targets against the core
swift test                  # headless smoke: catalog, settings, IPC, sidecar handshake
swift run PrivoVoice  # dev run — UI spawns the sidecar from .build/
```

For a real, double-clickable GUI app (menu-bar item, stable permissions):

```bash
./scripts/setup-signing.sh  # ONCE: create a stable self-signed identity so TCC
                            # grants (Microphone/Accessibility) persist
./scripts/make-app.sh       # → build/PrivoVoice.app  (bundles both binaries, signs)
open build/PrivoVoice.app
```

> **Run `setup-signing.sh` once.** Without it, `make-app.sh` falls back to ad-hoc
> signing, which changes the app's identity every build — so macOS forgets your
> Microphone / Accessibility grants and dictation silently stops working
> after each rebuild. The self-signed "PrivoVoice Dev" identity keeps one stable
> signature (needs Homebrew `openssl@3`; the first `codesign` shows one keychain
> prompt — click **Always Allow**). Local dev only; use a Developer ID to
> distribute.

Permissions:

1. **Microphone** — to capture your speech.
2. **Accessibility** — for the push-to-talk hotkey and to paste the transcript.

> **No Input Monitoring, ever.** The hotkey is a **consuming `CGEventTap`**
> (`kCGEventTapOptionDefault`) — the same approach Handy and OpenSuperWhisper use.
> A *consuming* tap requires **Accessibility**, not Input Monitoring (only the
> passive `.listenOnly` tap needs Input Monitoring). Since Accessibility is
> already needed to paste, the hotkey costs no extra permission. It works with
> **any** key or chord — including `fn`+Space and bare keys — and **consumes** the
> trigger, so it never types while you dictate. Default is **hold `fn`**.

> `swift run` works for development (the UI finds the sidecar next to itself in
> `.build/`). `make-app.sh` signs with the stable self-signed identity from
> `setup-signing.sh` (see above) so grants persist; for distribution, swap in a
> Developer ID identity and notarize the bundle.

## Models

Selecting a model in the **Models** tab downloads its `.aimodel` into the storage
location (default `~/Library/PrivoVoice/Models/`, changeable in Settings). Until the
converted assets are published to Hugging Face, use **Import…** on a card to
install a locally-converted asset (see [`../convert/`](../convert)); download
surfaces a clear "not yet published" message otherwise.

Each card shows what the model is good for: native streaming vs. re-transcribe,
speed and accuracy ratings, supported languages, on-disk size, leaderboard WER,
and the weights license.

## Notes & limitations

- The push-to-talk hotkey is a **consuming `CGEventTap`** (Accessibility, no Input
  Monitoring). Any key/chord works — `fn`, `fn`+Space, bare keys — and the trigger
  is consumed so it never types.
- Native streaming (live words) is Nemotron only; every other backend
  re-transcribes the growing utterance for live partials (see the root README's
  support matrix).
