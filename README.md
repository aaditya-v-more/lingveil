# Lingveil

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

While a translation is showing, hold ⌥ to see the original, rest the pointer on a block to read its original, and right-click to copy. All shortcuts can be changed in Settings.

## How it works

- **Text**: the frontmost app's Accessibility tree gives the exact strings, frames and fonts of its labels and messages. On-device OCR (Apple Vision) runs at the same time, confirms the text is visible and picks up everything Accessibility can't reach: images, video, games, canvas apps.
- **Look**: background and text colors are sampled from the pixels around and inside each piece of text (gradients included), font size comes from the original's measured width, and the translation is fitted into the original's box.
- **Translation engines**:
  - Automatic (default): Google Translate, with no key or account, falling back to Apple's on-device translation when offline.
  - Apple on-device: fully offline once a language pair is downloaded (Settings → Engines).
  - Your own Google Cloud or DeepL API key.
  - Ollama, for a local model of your choice.
- **Light on memory**: OCR runs in a helper process that quits after 90 seconds idle, so between uses the app holds only a few tens of MB. Live mode uses a ScreenCaptureKit stream that only delivers frames when pixels change.

## Build

```sh
./build.sh            # universal build into build/Lingveil.app
ARCHS=arm64 ./build.sh
```

Requires macOS 15 or later. The app asks for Screen Recording (required) and Accessibility (optional, for exact app text and translating selections).
