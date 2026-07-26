<div align="center">

# 🎙️ PrivoVoice

### Private, on-device dictation for macOS

**Hold a key. Speak. It's typed — wherever your cursor is.**
Your voice never leaves your Mac. No cloud. No account. No subscription.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS-black?logo=apple&logoColor=white)](#-quick-start)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#)
[![Engine: Voixful](https://img.shields.io/badge/engine-Voixful-4c9a6b)](https://github.com/AustinJiangH/voixful)
[![On-device](https://img.shields.io/badge/100%25-on--device-4c9a6b)](#-why-privovoice)

</div>

---

PrivoVoice turns **any** text field into a microphone. Press and hold your
shortcut, talk, release — the transcript lands at your cursor, in whatever app
you're using. Everything runs **100% on-device** on Apple Silicon through Apple's
Core AI runtime, powered by the [**Voixful**](https://github.com/AustinJiangH/voixful)
speech engine.

```mermaid
flowchart LR
    A["⌥ Hold shortcut"] --> B["🎤 Speak"] --> C["⌥ Release"] --> D["⌨️ Pasted at your cursor"]
```

*Nothing leaves your Mac — capture, transcription, and paste all happen on-device.*

## ✨ Why PrivoVoice

- 🔒 **Truly private** — audio is transcribed locally and never leaves the device. No network, no telemetry.
- ⌨️ **Works everywhere** — pastes into any app at the cursor; no per-app integration.
- ⚡ **Push-to-talk** — hold to talk, release to type. Your trigger key is *consumed*, so it never types while you dictate.
- 🧠 **Your choice of model** — from a 0.6 B streaming model for lowest latency to a 2.5 B model for the best punctuation. Download in-app.
- ✍️ **Optional transcript polish** — an on-device LLM (Qwen3 1.7B, MLX 4-bit, ~1 GB opt-in download) fixes punctuation and mis-hearings, strips filler words, applies spoken self-corrections ("Monday — no wait, Tuesday"), and formats spoken enumerations as numbered lists. Off by default; adds ~0.1–0.35 s per dictation once warm.
- 🛡️ **Minimal permissions** — Microphone + Accessibility only. **No Input Monitoring, ever.**
- 🧩 **Crash-isolated** — the model runs in a separate process, so an engine hiccup can't take the app down.
- 🆓 **Free & open source** — Apache-2.0, no account, no paywall.

## 🧠 Models

Pick a model in the **Models** tab and it downloads on-device. All are Apple
Core AI (Palette4) conversions, published on Hugging Face:

- 🟢 **[Nemotron Streaming](https://huggingface.co/AustinJiangH/voixful-nemotron-speech-streaming-en-0.6b)** — English · *streams live* · NVIDIA Open Model
  Lowest-latency dictation — words appear *while* you speak.
- 🐦 **[Parakeet TDT v2](https://huggingface.co/AustinJiangH/voixful-parakeet-tdt-0.6b-v2)** — English · CC-BY-4.0
  Smallest and fastest, with the best English accuracy of the small tier.
- 🌍 **[Parakeet TDT v3](https://huggingface.co/AustinJiangH/voixful-parakeet-tdt-0.6b-v3)** — 25 European languages · CC-BY-4.0
  Multilingual, still fast.
- 🎯 **[Granite Speech NAR](https://huggingface.co/AustinJiangH/voixful-granite-speech-4.1-2b-nar)** — en · fr · de · es · pt · Apache-2.0
  The most accurate overall.
- ✍️ **[Canary-Qwen](https://huggingface.co/AustinJiangH/voixful-canary-qwen-2.5b)** — English · CC-BY-4.0
  The best punctuation and casing.

> Only Nemotron streams natively; the others re-transcribe the growing utterance
> for live partials. Each card in the app shows speed, accuracy, size, and
> language support at a glance.

## 🚀 Quick start

> **Prerequisite:** PrivoVoice is built on the [Voixful](https://github.com/AustinJiangH/voixful)
> speech engine, referenced as a sibling package (`../voixful`). Clone both next to each other:

```bash
git clone https://github.com/AustinJiangH/voixful.git
git clone https://github.com/AustinJiangH/PrivoVoice.git
cd PrivoVoice
```

Run it:

```bash
swift run PrivoVoice          # dev run (menu-bar app)
```

Or build a real, double-clickable `.app`:

```bash
./scripts/setup-signing.sh    # once — stable signing so permissions persist
./scripts/make-app.sh         # → build/PrivoVoice.app
open build/PrivoVoice.app
```

Then: open **Models**, download one, hit **Use this model**, grant the two
permissions below, and **hold `fn`** to dictate.

## 🔒 Permissions

1. **Microphone** — to hear you.
2. **Accessibility** — for the push-to-talk hotkey and to paste the transcript.

<details>
<summary><b>Why no Input Monitoring?</b></summary>

The hotkey is a **consuming `CGEventTap`** (`kCGEventTapOptionDefault`) — the same
approach [Handy](https://github.com/cjpais/Handy) and OpenSuperWhisper use. A
*consuming* tap requires **Accessibility**, not Input Monitoring (only a passive
`.listenOnly` tap needs Input Monitoring). Since Accessibility is already needed
to paste, the hotkey costs no extra permission — and because the tap *consumes*
the trigger, any key/chord works (including `fn`, `fn`+Space, bare keys) without
typing while you dictate. Default is **hold `fn`**.
</details>

<details>
<summary><b>Stable signing (so grants persist across rebuilds)</b></summary>

`make-app.sh` signs with the self-signed **PrivoVoice Dev** identity created by
`setup-signing.sh` (needs Homebrew `openssl@3`; the first `codesign` shows one
keychain prompt — click **Always Allow**). Ad-hoc signing changes identity every
build, so macOS would forget your grants — that's what the stable identity fixes.
Local dev only; use a Developer ID + notarization to distribute.
</details>

## 🏗️ Architecture

Two processes, so a crash or hang in the (beta) Core AI runtime can't take the UI
down — the native equivalent of how Handy isolates its Rust core:

```mermaid
flowchart LR
    UI["🖥️ PrivoVoice · UI process<br/>menu bar · hotkey · mic · HUD · paste<br/><i>holds Mic + Accessibility</i>"]
    ENG["⚙️ PrivoVoiceHelper · engine process<br/>loads the .aimodel · drives Voixful<br/><i>no permissions — audio in, text out</i>"]
    UI -->|"begin / audio frames →"| ENG
    ENG -->|"← partial / final text"| UI
```

<details>
<summary><b>Targets & the reusable core</b></summary>

The app splits into portable and macOS-only pieces so the non-UI logic could power a future iOS app too:

- **`PrivoVoiceKit`** *(portable)* — model catalog, download/store, settings, `AudioCapture`, `DictationController`, the `DictationEngine` protocol + in-process engine, and the optional transcript formatter (`Formatting/`: MLX LLM with prefix-KV caching). No AppKit/SwiftUI.
- **`PrivoVoiceIPC`** *(portable)* — the tiny stdio wire protocol shared by both processes.
- **`PrivoVoiceApp`** *(macOS)* — SwiftUI UI (Settings + Models), HUD, menu bar, hotkey, paste, and the sidecar-spawning engine.
- **`PrivoVoiceHelper`** *(macOS)* — the resident engine process (the sidecar); also hosts the resident formatter LLM when transcript polish is on.

The split hides behind the `DictationEngine` protocol: macOS injects the sidecar;
a future iOS app reuses `PrivoVoiceKit` with the in-process engine instead — no
other change.
</details>

## 🌱 Built on Voixful

PrivoVoice is the app; **[Voixful](https://github.com/AustinJiangH/voixful) is the
engine.** Voixful is an open-source, `SpeechAnalyzer`-shaped API over local speech
models on Apple Silicon (Core AI) — it handles mel extraction, model loading, and
transcription across every backend (Nemotron, Parakeet, Granite, Canary, …).
PrivoVoice adds the product on top: the push-to-talk UX, model management, the
floating HUD, and the two-process sandboxing.

> Want to build your own on-device speech app? Start with **[Voixful](https://github.com/AustinJiangH/voixful)**.
> Just want to dictate? That's **PrivoVoice**. 💚

## 📄 License

PrivoVoice — app code © 2026 Austin Jiang, **Apache-2.0** (see [`LICENSE`](LICENSE)).
Built on [Voixful](https://github.com/AustinJiangH/voixful) (also Apache-2.0).

Model **weights** are downloaded separately and carry their own upstream licenses
(CC-BY-4.0 · Apache-2.0 · NVIDIA Open Model License) — see each model card on
Hugging Face. Keep the weights' licenses separate from this Apache-2.0 code when
you redistribute.
