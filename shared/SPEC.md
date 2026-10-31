# Lingveil behavior spec

Both apps (macOS in `Sources/`, Windows in `windows/`) follow this document so a screen
translates the same way on either. Data that both read lives next to it:

- `models.json`: local model catalog (display order, ratings, download URL + sha256),
  prompt templates per model family, llama.cpp server arguments.
- `languages.json`: target languages (`code` is the id used everywhere; Google uses it directly).

When either app changes a constant below, update this file in the same commit.

Coordinates: everything here is in **points of the captured image with the origin at the
top-left**, and "h" means the line's height. The Mac app converts from AppKit's bottom-left
global space; Windows works in physical pixels divided by the monitor's scale.

## 1. Modes and shortcuts

| Action | Default shortcut (Mac / Windows) | Behavior |
|---|---|---|
| Translate screen | ⌥⇧T / Alt+Shift+T | Whole monitor under the pointer. Same shortcut, click, scroll, Esc or switching apps closes it. |
| Translate area | ⌥⇧A / Alt+Shift+A | Drag a rectangle (dim the screen, Esc or right-click cancels), then as above. |
| Live area | ⌥⇧L / Alt+Shift+L | Drag a rectangle; it stays translated while its pixels change. Same shortcut or ⌥Esc / Alt+Esc stops. Overlay is click-through with an accent border. |
| Under pointer | ⌥⇧D / Alt+Shift+D | Card with the translation of the paragraph under the pointer (original underneath, Copy button). |
| Selection | ⌥⇧S / Alt+Shift+S | Card with the translation of the selected text in the front app. |
| Hover | hold ⌥ / Alt (opt-in) | Pointer resting ~0.3 s over text shows the pointer card. |

While a screen/area translation is showing: hold ⌥/Alt to hide it (peek at the original),
resting on a block for 0.7 s shows its original as a tooltip, right-click offers Copy
Translation / Copy Original / Copy All / Close.

## 2. Pipeline

```
capture → text items (accessibility ∥ OCR) → filter → translate (batched, progressive) → colors → paint
```

### 2.1 Capture
- Capture the monitor (or area) at full resolution, **excluding Lingveil's own windows**
  (Mac: ScreenCaptureKit filter that excludes the app; Windows: `WDA_EXCLUDEFROMCAPTURE`
  on every Lingveil window). If the exclusion fails, live mode reads its own overlay and
  flickers, so verify it.
- Convert the capture once into a plain BGRA buffer that the app allocates and frees itself.
  OCR and color sampling both read that buffer, and it is freed when the overlay closes.

### 2.2 Text from accessibility (front app only)
- Walk the front window's tree (Mac AX / Windows UI Automation) with a **350 ms budget**,
  max depth 60, max 6000 nodes. Skip subtrees whose frame doesn't intersect the area.
- Text roles: static text (always), text areas/fields **only when not editable** (never
  repaint what the user is typing). Titled roles: buttons, menu buttons, pop-ups, check
  boxes, radio buttons, menu items, menu-bar items, tabs, disclosure triangles.
- Use the glyph bounds of the text range when available (Mac `AXBoundsForRange`, Windows
  `TextPattern.GetBoundingRectangles`), else the element frame. Keep an item only if at
  least 60% of its height and 50% of its width is inside the visible clip (window ∩ scroll areas).
- Font: from the text attributes when available (name + size); otherwise estimated (2.4).
- Chromium/Electron need their tree switched on (Mac: `AXManualAccessibility`; Windows:
  UIA usually works once a client asks).

### 2.3 Text from OCR (runs at the same time)
- Accurate recognition with language correction, automatic language detection, minimum
  text height 7 pt. Drop candidates below 0.3 confidence.
- **Label rows**: OCR often returns a row of separate labels (menu bar, toolbar) as one
  line. Split a line when it is wider than 1.2× the width its text would take in the
  system font at size h, at every word whose box is wider than its measured width by more
  than 1.0×h.
- **Paragraphs**: walk lines top to bottom and merge line B into the paragraph ending in
  line A when all hold: vertical gap −0.3h…0.7h; heights within 30%; horizontal overlap;
  left edges within 1.2h or centers within 1.2h; A is "long" (wider than max(9h, 60% of the
  paragraph)); A doesn't end with `. ! ? 。 ！ ？ : ：`. Join with a space (no space for CJK;
  a trailing hyphen joins words). A paragraph whose line centers vary less than half as much
  as its left edges is centered.

### 2.4 Merging and sizes
- Keep an accessibility item only if some OCR text overlaps it (proves it is visible), and
  drop duplicates (same text, >50% overlap).
- Add OCR items that don't overlap any kept accessibility item by more than 25% of their area.
- OCR font size: by height = h × 0.8 (single line) or h × 0.74 (multi-line); for single lines
  prefer the size at which the text measured in the system font matches the box width,
  clamped to 0.75…1.15 × the height estimate; minimum 7. Then **snap**: sort sizes, chain any
  size ≤ 1.1× its predecessor into one cluster, give every item its cluster's median
  (rounded to 0.5). OCR text is drawn in the regular system font weight.

### 2.5 Filter (never translated, original stays visible)
- No letters (numbers, symbols).
- Literals: contains `://`, starts with `www.` `/` `~/` `@` `#`; a single token that is an
  email, a file name (`^[^\s.][^\s]*\.[a-z][a-z0-9]{0,4}$`), or code (`_`, `/`, `\`,
  camelCase, `()`).
- Already in the target language: language detector's top guess is the target with
  confidence > 0.6 (≥ 3 words) or > 0.8 (shorter), text ≥ 4 characters.
- After translating: empty results, results equal to the original (case-insensitive), and
  lines Google reports as already in the target language.

### 2.6 Translation
- Order: items inside the front window first, then top to bottom.
- Batches: 30 items for online engines, Automatic included (all batches sent at once); 8 items for local
  engines (one batch at a time — the server already runs lines in parallel). Paint each
  batch as it lands.
- Cache: translation per (target, text), up to 20,000 entries, shared by all modes.
- **Google (default, no key)**: `POST https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=<code>`,
  body `application/x-www-form-urlencoded`, one `q=` per string, chunks of ≤ 30 strings /
  1500 characters in parallel, 6 s timeout. Reply is `[[translation, detectedLang], ...]`;
  a single string may come back flattened as `[translation, lang]`. Open the HTTPS connection
  (a throwaway `q=ok` request) as soon as a shortcut fires so the real request skips TLS setup.
- **Automatic** engine = Google, and on any error the offline engine: the chosen local model
  if downloaded and it supports the target, else the OS translator (Mac: Apple Translation,
  grouping lines by detected language; Windows has none, so it says to download a model).
- Google Cloud (user key, v2 `q[]`), DeepL (user key, `:fx` = free host), Ollama
  (`/api/chat`, JSON `{"t": [...]}`) are optional.
- **Capitalization**: if the translation starts lowercase, uppercase it when the original
  started uppercase or has no case (CJK, Devanagari…).

### 2.7 Local models (llama.cpp)
- Bundled `llama-server`, started on first use with `models.json → server.args` plus
  `-m <file> --host 127.0.0.1 --port <free> -t <cores/2>`, at low priority. Wait for
  `GET /health` = 200 (≤ 30 s).
- **Exactly one server**: concurrent requests share one start; a model that failed to start
  isn't retried for 30 s; stop it after `idleStopSeconds` idle or on memory pressure; kill
  leftovers from a previous run at launch; **the server must die with the app** even on a
  crash (Mac: a guard process reading the app's pipe; Windows: Job object with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`). An orphaned server pile-up made the screen stutter.
- One request per line, `server.parallel` at a time. Fill the family's template
  (`{target}`, `{targetCode}`, `{targetChinese}`, `{source}`, `{sourceCode}`, `{text}`),
  send to `/v1/chat/completions` (`endpoint: chat`, plus `server.chatExtra`) or `/completion`
  (`endpoint: completion`), `max_tokens = min(1024, 4 × characters + 48)`, plus the
  template's `params`.
- Clean output: drop everything up to `</think>`, remove `<end_of_turn>`, trim, strip a
  leading `Translation:` / `翻译：` / `译文：`.
- Downloads: from `https://huggingface.co/<repo>/resolve/main/<file>` into the app's
  models folder, resumable, staged as `<file>.part`, **sha256 must match** before it counts
  as installed; refuse when free disk < size + 1 GB.

### 2.8 Colors (per item, from the capture)
- Ring = clamp(0.15h, 2…6) px around the text box. Background top = median of the ring
  above + half the side pixels; bottom = median of the ring below + the other half. If top
  and bottom differ by < 0.05 (RGB distance, 0–1 channels), use the whole ring's median for both.
- Text color: inner pixels whose distance from the row-interpolated background is > 0.18;
  take the 25% farthest and their median. Fewer than 4 such pixels, or luma contrast with
  the background < 0.25 → near-black or near-white by background luma.
- Sample at most ~40,000 pixels per item (stride).

### 2.9 Painting
- Fill rect = text box grown by max(2, 0.18h) horizontally and max(1, 0.1h) vertically,
  corner radius 2 (seamless) or 5 with a soft shadow and hairline border (card style).
  Vertical gradient top→bottom when the background is a gradient.
- Fit: start at the item's font (or estimated size), shrink in 0.5 pt steps down to 0.76×
  while the wrapped text is taller than 1.06× the box; a single line may then widen up to
  1.6× (centered items grow both ways); then shrink to max(7, 0.7×); if still too tall,
  extend the box downward rather than truncate. Center the text vertically.
- Fade the overlay in over 120 ms, out over 100 ms. Never animate text that is being read.

### 2.10 Live mode
- Stream the area at ≤ 4 fps. Skip frames whose 64×64 luma fingerprint differs from the
  previous one in ≤ 2 cells (difference > 12/255) — some systems report every frame as new.
- After a change, wait until frames stop changing for 250 ms, then run the pipeline on the
  newest frame; repaint all blocks at once.

### 2.11 Pointer and selection cards
- Pointer: the accessibility element under the pointer (never Lingveil's own windows);
  in a multi-paragraph text view take only the paragraph under the pointer; otherwise
  the element's value/title or its static-text children. Fallback: OCR a 900×280 area
  around the pointer and take the block under it, else the nearest.
- Selection: ask the front app's focused element for its selected text first, then the
  system-wide focused element.
- Card: below the text (above if no room), max width 380, translation 14 pt, original
  11 pt secondary (≤ 4 lines), Copy button; closes on click, scroll or Esc.

## 2.12 Platform notes (same intent, different mechanics)

Windows:
- OCR (Windows.Media.Ocr) boxes cover only the ink. Estimate em = ink height / 0.73 (no
  descenders), / 0.95 (descenders) or / 0.9 (CJK), and grow each line box to baseline
  −0.98 em … +0.27 em so it matches the ~1.25 em line boxes the constants above assume.
- Label-row split: word boxes are tight there, so split at an inter-word gap > 1.0 em.
- Windows OCR runs one engine per language and needs that language's OCR pack. The app
  lists installed packs, recognizes with the packs for the languages the user reads, and
  offers to install missing ones (Add-WindowsCapability `Language.OCR~~~<tag>~0.0.1.0`,
  which asks for admin rights).
- "Already in the target language" uses script share (> 80% of letters) for non-Latin
  targets; Latin/Cyrillic targets rely on Google's detected language.
- Fitting: fallback fonts (Nirmala UI, Yu Gothic) have tall line metrics, so a block also
  fits when it uses no more lines than the original; no ellipsis trimming.
- Offline engine is the local model only (there is no OS translator).

## 3. Resources and memory
- Idle app: tens of MB. OCR models (~120 MB on Mac) live in a helper process that exits
  after 90 s idle; the model server stops after `idleStopSeconds`.
- First OCR after install can be slow (model compile): warm it in the background at launch.

## 4. Testing hooks (both apps)
- Headless render: run the pipeline on a PNG treated as a 2× screen and write the image with
  the translation painted on (Mac: `LINGVEIL_DEBUG_IMAGE` / `LINGVEIL_DEBUG_OUT`).
- Text bench: translate `bench/*.txt` with any engine and write outputs for
  `bench/score.py` (Mac: `LINGVEIL_DEBUG_TEXTS`, `LINGVEIL_DEBUG_TEXTS_OUT`, `LINGVEIL_ENGINE`,
  `LINGVEIL_LOCAL_MODEL`, `LINGVEIL_TARGET`; target and engine overrides never persist).
- Live trigger: a debug mode where an external signal runs a real action and saves a
  screenshot including the overlay plus timings.
