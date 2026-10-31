# Lingveil

<p>
  <a href="https://ko-fi.com/aadityavmore"><img alt="Support this on Ko-fi" src="https://img.shields.io/badge/Ko--fi-support-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white&labelColor=1F1B16"></a>
</p>

Translate whatever is on your Mac's screen, in place. Press a shortcut and every label, message and paragraph is repainted in your language, in the same spot, with the app's own colors and type, so the window looks as if it had been written in that language.

Free, native (Swift/AppKit), menu bar only.

## Shortcuts

| Shortcut | What it does |
| --- | --- |
| ⌥⇧T | Translate the screen under the pointer (press again, click, scroll or Esc to close) |
| ⌥⇧A | Translate an area you drag out |
| ⌥⇧L | Live-translate an area: keeps up as it changes (subtitles, chats, games). ⌥Esc stops |
| ⌥⇧D | Translate the text under the pointer in a small card |
| ⌥⇧S | Translate the selected text in a small card |
| ⌥⇧C | Copy text from an area: drag over anything and its text goes on the clipboard |

While a translation is showing, hold ⌥ to see the original, rest the pointer on a block to read its original, and right-click to copy. All shortcuts can be changed in Settings.

## How it works

- **Text**: the frontmost app's Accessibility tree gives the exact strings, frames and fonts of its labels and messages. On-device OCR (Apple Vision) runs at the same time, confirms the text is visible and picks up everything Accessibility can't reach: images, video, games, canvas apps.
- **Look**: background and text colors are sampled from the pixels around and inside each piece of text (gradients included), font size comes from the original's measured width, and the translation is fitted into the original's box.
- **Translation engines**:
  - Automatic (default): Google Translate, with no key or account; offline it switches to your local model, or to Apple's.
  - Local models, downloaded from Settings → Models and run on this Mac through a bundled llama.cpp server. Nothing needs installing. Tested picks for 8 GB Macs:

    | Model | Download | Speed | Accuracy |
    | --- | --- | --- | --- |
    | Index-Translate 2B (best balance, default) | 1.3 GB | ●●●●○ | ●●●●○ |
    | Hy-MT2 1.8B (fastest) | 1.1 GB | ●●●●● | ●●●○○ |
    | Gemma 4 E2B (most accurate) | 2.8 GB | ●●●○○ | ●●●●● |

    Larger models (Hy-MT2 7B, Index-Translate 9B, TranslateGemma 4B/12B, Gemma 4 E4B, Hy-MT2 30B-A3B) are listed too, with the memory they need. Method and numbers: [bench/BENCHMARKS.md](bench/BENCHMARKS.md).
  - Apple Translation: the models built into macOS (high quality, or the fast ones on macOS 26.4+), downloaded per language pair.
  - Your own Google Cloud or DeepL API key, or Ollama / another local server.
- **Light on memory**: OCR runs in a helper process that quits after 90 seconds idle, and a local model's server stops after 3 idle minutes or when macOS is short of memory, so between uses the app holds only a few tens of MB. Live mode only re-reads the area when its pixels change.

## Layout

- `Sources/` — the macOS app (Swift, AppKit).
- `windows/` — the Windows app (C#, .NET 8, WPF).
- `shared/` — what both read: `models.json` (local model catalog, prompts, server settings), `languages.json`, and `SPEC.md`, the behavior both apps follow.
- `bench/` — translation test sets, runner and scorer behind the model ratings.

## Build

```sh
./build.sh            # universal build into build/Lingveil.app
ARCHS=arm64 ./build.sh
```

Requires macOS 15 or later; local models need Apple silicon. `build.sh` builds llama.cpp's server from `../llama.cpp` (or `LLAMA_CPP_DIR`) the first time. The app asks for Screen Recording (required) and Accessibility (optional, for exact app text and translating selections).

## Support

Lingveil is free. The ♥ Donate button in the top-right corner of Settings, and *Support
Lingveil on Ko-fi…* in the menu bar, open Ko-fi. If it helps you read the web or your apps,
you can [buy me a coffee on Ko-fi](https://ko-fi.com/aadityavmore).
