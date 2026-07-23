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

| Product | Platform | Contents |
|---|---|---|
| **`VoixfulKit`** | portable (macOS / iOS) | Model catalog, download/store, settings, and the `DictationController` that drives `VoixfulAnalyzer`. No AppKit/SwiftUI. |
| **`VoixfulApp`** | macOS | SwiftUI sidebar (Settings + Models), floating HUD, menu-bar item, global push-to-talk hotkey, paste-at-cursor. |

`VoixfulKit` depends only on the Voixful core libraries and Foundation/AVFoundation.
The macOS-only glue (a `CGEventTap` hotkey, `CGEvent` paste, `NSPanel` HUD,
`MenuBarExtra`) lives entirely in `VoixfulApp`. To build an iOS app, reuse
`VoixfulKit` and write a new UI + capture trigger.

```
app/
├── Package.swift                 # depends on the root package via path: ".."
├── Sources/
│   ├── VoixfulKit/               # reusable core
│   │   ├── Catalog/ModelCatalog.swift
│   │   ├── Settings/{AppSettings,KeyCombo}.swift
│   │   ├── Store/{ModelStore,ModelDownloader}.swift
│   │   └── Session/{AppState,AudioCapture,TranscriberFactory,DictationController}.swift
│   └── VoixfulApp/               # macOS SwiftUI app
│       ├── App/                  # scenes, environment, AppKit delegate
│       ├── Hotkey/ Paste/ HUD/ MenuBar/ UI/
│       └── Info.plist            # mic usage + LSUIElement (embedded via linker)
└── Tests/VoixfulKitTests/        # headless smoke coverage (no model, no GUI)
```

## Build & run

```bash
cd app
swift build                 # compiles VoixfulKit + VoixfulApp against the core
swift test                  # headless Kit smoke tests
swift run VoixfulDictation  # launches the menu-bar app
```

The first launch prompts for two permissions:

1. **Microphone** — to capture your speech (declared in the embedded Info.plist).
2. **Accessibility / Input Monitoring** — for the global push-to-talk hotkey and
   paste-at-cursor. Grant it in *System Settings → Privacy & Security*, then
   relaunch.

> `swift run` produces a bare executable, not a signed `.app` bundle. That's fine
> for development. For distribution, wrap the binary in an app bundle with the
> `Info.plist`, code-sign, and notarize.

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
