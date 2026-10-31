# Lingveil behavior spec

Both apps (macOS in `Sources/`, Windows in `windows/`) follow this document so a screen
translates the same way on either. Data that both read lives next to it:

- `models.json`: local model catalog (display order, ratings computed by `bench/rate.py`
  from measurements, download URL + sha256),
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
| Live area | ⌥⇧L / Alt+Shift+L | Drag a rectangle; it stays translated while its pixels change and follows its text while it scrolls, the same way as 2.12b (moving blocks with the text, reading only what is new). Same shortcut or ⌥Esc / Alt+Esc stops. Overlay is click-through with an accent border. |
| Under pointer | ⌥⇧D / Alt+Shift+D | Card with the translation of the paragraph under the pointer (original underneath, Copy button). |
| Selection | ⌥⇧S / Alt+Shift+S | Card with the translation of the selected text in the front app. |
| Hover | hold ⌥ / Alt (opt-in) | Pointer resting ~0.3 s over text shows the pointer card. |
| Read aloud | ⌥⇧R / Alt+Shift+R | Reads, in order of preference: the translation showing (in reading order, outlining each block), the selected text, or the front window's text in reading order (title bar skipped). Same shortcut or Esc stops. |
| Translate and read aloud | ⌥⇧E / Alt+Shift+E | Selection → translate, show the card and read the translation. Otherwise translate the front window in place, then read it as above. |

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
- Keep an accessibility item only if OCR items lie inside it (each with ≥ 50% of its area
  inside; proves it is visible), and drop duplicates (same text, > 50% overlap). Its line
  count is the sum of those OCR items' lines. When it has no font (web and Electron apps
  give none), or its font size is outside 0.6–1.6× the OCR size, take the size (median of
  the OCR items) and the box (union of the OCR items) from OCR; letters OCR missed at either end are added from the pixels (2.9).
- Add OCR items that don't overlap any kept accessibility item by more than 25% of their area.
- OCR font size: by height = h × 0.8 (single line) or h × 0.74 (multi-line); for single lines
  prefer the size at which the text measured in the system font matches the box width,
  clamped to 0.6…1.4 × the height estimate (text ≥ 4 characters); paragraphs: the glyph
  height of their single lines × 0.8, checked against the summed width of
  those lines (size at which the text measures that wide), clamped to 0.6…1.1×; minimum 7. Then **snap** single lines only: sort,
  start a cluster at the smallest size and add sizes ≤ 1.12× that first member; every item
  gets its cluster's median (rounded to 0.5). OCR text is drawn in the regular system font weight.

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
- Bundled `llama-server`, started on first use with `models.json → server.args` plus the
  model's prompt family `serverArgs` (chat families need `--jinja`; TranslateGemma's own
  template breaks llama.cpp's template engine, so it runs with `--no-jinja --chat-template gemma`) plus
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
- **Measure from the pixels first** (per block, in the capture): background = most common
  color (4 bits per channel buckets) of a 1–3 px ring around the text; ink = pixels farther
  than max(0.16, 0.45 × |text − bg|) from the background *and* within max(0.2, 0.55 × |text − bg|)
  of the text color (icons and controls next to a label don't count). Trim the box to the
  first/last ink column, then extend it while ink continues (stop after a 0.33-line gap,
  look at most 2 lines out). Free space: skip a fringe of ≤ 0.25 line of non-background
  columns, then count background columns (distance < 0.07) up to max(1.5 × width, 8 lines);
  hitting a non-background column means that side is bounded. Same up/down, at most half a line.
- Gradient only when two opposite sides of the ring differ (> 0.05), each side is plain
  (≥ 60% one color) and the other two sides sit between them; else one flat color.
- **Alignment of single lines**: equal free space on both sides (within 30% when both bounded,
  8% otherwise) → centered (buttons, tabs, dialog titles); shares its right edge (±2.5 pt)
  with a block within 4 lines above/below but not its left edge → right; bounded right
  within 0.6 line with > 3 lines free on the left → right; else as detected.
- **Weight**: stroke = median length of horizontal ink runs ÷ line height. Relative to the
  screen's median stroke: ≥ 1.75× bold, ≥ 1.45× semibold, else regular.
- Fill rect = text area plus padding of max(2, 0.18h) sideways and max(1, 0.1h) vertically,
  but padding only extends into measured free background (never over a border).
  Corner radius 2 (seamless) or 5 with a soft shadow and hairline border (card style).
- **Single line**: widen into measured free space first (up to 2.5×, on the side the
  alignment allows, never off screen, and taking at most half of a gap shared with a
  neighbouring block in the same row: (gap / 2 − 1)), then shrink in
  0.5 pt steps to max(7, 0.6×), then truncate the tail. Never wrap. Draw one line of the
  font's own height centered on the original line's midline.
- **Paragraph**: shrink to max(7, 0.7×) while taller than 1.06× the box; then grow downward
  only into free space (≤ 0.5× the box), shrink to max(7, 0.55×), truncate. Text starts at
  the original first line.
- **One size per column**: single-line blocks anchored on the same edge with the same original
  size are capped at the group's median fitted size (a single long item that had to shrink
  further keeps its own size).
- Drop a block that overlaps a better one by > 30% of the smaller (accessibility text first,
  then the larger block).
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
  which asks for admin rights). Settings has a "Languages I read on screen" list with each
  pack's state. All listed, installed engines run in parallel; where their boxes overlap,
  keep the result whose script matches the engine's language, else the one with more
  letters. If nothing is found while a listed language lacks its pack, the pill says to
  install that language's text recognition instead of "Nothing to translate".
- "Already in the target language" uses script share (> 80% of letters) for non-Latin
  targets; Latin/Cyrillic targets rely on Google's detected language.
- Fitting: fallback fonts (Nirmala UI, Yu Gothic) have tall line metrics, so a block also
  fits when it uses no more lines than the original; no ellipsis trimming.
- Offline engine is the local model only (there is no OS translator).
- llama-server (Vulkan build) is started with `VK_LOADER_LAYERS_DISABLE=~implicit~`: on
  laptops with switchable AMD + NVIDIA graphics an implicit Vulkan layer hangs startup forever.
- UI Automation gives element frames, not glyph bounds or fonts, so UIA items take their box,
  line count and size from the OCR lines inside them (same rule as 2.4).

### 2.12b Staying translated (toggle "Keep translating while you scroll and use the app", default on)
- Translate Screen follows the front app's window (not the whole screen); a picked area
  stays that area. The overlay is click-through, so the app is used normally; Esc is left
  to the app. It ends with the shortcut again, the ✕ on a small bar at the bottom
  ("Translated to <language>", spinner while re-reading), or another app coming forward.
  Moving or resizing the window starts over on its new frame; closing it ends.
- Drawing: each block is painted once into its own layer; following only moves layers
  (no relayout). A re-read keeps the layer of any block with the same translation at the
  same spot (no flicker); new blocks fade in over 0.12 s, blocks whose text left fade out.
- Motion: a capture stream of the followed area at full resolution, up to 60 fps,
  delivering only changed frames (same 64×64 fingerprint as Live). Per frame: brightness at
  one sample per point; per vertical band (4) find the vertical move against the reference
  frame (8× smaller copy, search ±70% of the height, then refine ±8 px), each scored ×
  (1 + |move − previous move| / 300) so repeated text doesn't jump. Each block then takes
  whichever of those moves, 0 or its previous move matches its own pixels best, judged in
  up to 8 side-by-side pieces using the 60th-percentile piece (a scroll bar, pointer or
  caret over part of it doesn't count), mean difference ÷ block contrast < 0.35. No match
  → hide it until re-read.
- Shown position = measured + speed × (frame age + 4 ms), speed from the last two frames'
  display times; when frames stop for 45 ms, settle on the measured position.
- Re-reading uses the tracked frames themselves (so text and positions come from the same
  moment): 0.12 s after things stop, and every 0.25 s while scrolling slower than
  1500 pt/s. Only what isn't followed yet is read: a grid of 32×8 pt cells; a cell needs
  reading if it has edges in it (≥ 4 brightness steps > 28) and no followed box covers it;
  needed cells are joined into horizontal strips (while scrolling, leave out 10 pt at the
  top and bottom edges: lines cut there are read when whole). All strips go to the
  recognizer as one stacked image (24 px between strips, padded with each row's last pixel),
  accurate mode, with the page's languages once known (learned from the first full read:
  language guesses > 0.15, plus English). If strips cover > 60% of the area, read it all.
  Areas read that need no translation (code, numbers, text already in the target
  language, pictures without text) are followed too, so they aren't read again.
  After 1 s of stillness following partial reads, read the whole area once with
  accessibility (exact text, fonts). Never use Vision's fast mode for this: it can't read
  non-Latin scripts and is worse below ~13 pt (bench/ocr).
  A still read starts even if a moving one is in flight; results older than what is shown
  are dropped. Blocks read from an older frame are moved to where their text is now before
  they appear.
- Scrolling back: when a block leaves (scrolled away or changed), keep it with its pixels
  as they were when it was read (up to 300). While text is unread (scrolling slower than
  1500 pt/s, at most every 80 ms, off the main thread), slide each remembered picture up
  and down over the unread strips at its own x (row-profile pass, then pixels at the best
  3 spots; mean difference ÷ contrast < 0.15) and put matches straight back: no reading,
  no translating.
- Ahead of time: text the app reports beyond the window (web pages, documents), up to two
  window heights above and below, is translated into the cache when following starts
  (not for models running on the device).
- Measured with `harness` (debug) + `bench/follow.py`; see bench/BENCHMARKS.md.

### 2.12c Copy text from an area (⌥⇧C)
- Pick an area like Translate Area; read it (accessibility for the front app where it has
  the text, otherwise OCR, accurate, any language) and put plain text on the clipboard.
- Order: reading order (2.14). Between blocks: a tab when the next one is on the same row
  to the right (form rows, table cells), a blank line when the gap is more than 1.2 line
  heights, otherwise a newline. Toast "Copied N lines of text" (one line: "Copied: <start>").
- Nothing found: toast "No text found there".

### 2.13 Web pages (toggle "Translate web pages by paragraph", default on)
- Applies to text inside any web area (every browser, and web-based apps), detected from
  the accessibility tree, not by app name. Accessibility budget 600 ms instead of 350.
- Each text run remembers its nearest paragraph-level ancestor: walking down from the web
  area, every element that is not inline (link, static text, emphasis, strong, mark, code)
  starts a new block. Consecutive runs of the same block are joined into one item (one
  translation) when they share a line (vertical overlap > 0.3 line) and follow on closely
  (horizontal gap < 1.5 lines). Join with a space unless one side already has one or the
  next starts with `, . ; : ! ? )`. Stacked labels and right-hand badges stay separate.

### 2.14 Read aloud
- Segments: (text, on-screen box, language). Order with an XY-cut: split into columns where
  a vertical gap > 18 pt runs the full height, except when the two sides line up row by row
  (≥ 60% of left boxes have a right partner at the same height: a form); otherwise split
  into stacked groups at horizontal gaps > 2 pt; a single row reads left to right.
- Outline the segment being read: on the translation overlay, a 2 pt accent outline around
  its block; for original text, a click-through outline window with a 10% accent tint.
- Engines (Settings → Voices): the OS voices (Mac: AVSpeechSynthesizer, best installed
  voice per language: Premium > Enhanced > default, user choice per language; Windows:
  Windows.Media.SpeechSynthesis / OneCore, including natural voices), or a plugin from
  `engines.json` (same format as Earmark): `{name, url | command, voices, speed: "engine" |
  "player", start}`. HTTP: POST `{text, voice, rate}` → WAV; `voices` URL lists
  `[{id, name, language, gender}]`; `start` runs once if the server can't be reached.
  Fetch the next segment's audio while the current one plays. Lines in a language the
  plugin has no voice for fall back to the OS voice. With OS voices, lines in a language
  with no installed voice are skipped with a one-time hint on how to add one.
- Speed 0.5–3× (1 = normal). The cards get a speaker button.
- Google voices: Settings → Voices → Install runs google-tts-local's installer
  (Mac: Homebrew formula; Windows: its Windows build when ready) and adds a "Google" plugin
  pointing at 127.0.0.1:5591.
- Narration models (`shared/voices.json`): open-source voices run through sherpa-onnx
  **1.13.8** (2.x dropped espeak-ng, which Piper, Kitten and Kokoro need). The runtime is
  downloaded with the first model (Mac: `runtime.mac-arm64`, keep only the listed
  libraries; Windows: the matching win-x64 shared build) into `<app data>/Voices/runtime`;
  each model's .tar.bz2 is checked against `sha256` and unpacked to `<app data>/Voices/<id>/`.
  Deleting the last model deletes the runtime too.
- Helper protocol (Mac: `Sources/Helpers/tts.c`, a small C program that loads the runtime
  with dlopen): `lingveil-tts <runtime dir> <kind> <model dir> <threads>`, where kind is
  vits | kokoro | kitten | supertonic. Stdin, one request per line:
  `<speaker>\t<speed>\t<language>\t<text>\n` (tabs/newlines in text become spaces). Stdout
  per request: int32 sample rate, int32 sample count (-1 = error), then float32 samples
  (little-endian). It exits after 2 idle minutes or when stdin closes, so no guard process
  is needed. Kokoro reloads when the language changes (its pronunciation language is fixed
  at load). One helper per model.
- Speaker: `speakers[language] ?? speakers[base] ?? speakers.default`. Split each segment
  into sentences; make sentence n+1 while n plays, and the next segment's first sentence ahead.
- Which model reads a language: the chosen one, unless another downloaded model's measured
  `errorRate[lang]` is under half of the chosen one's; if the chosen model doesn't speak the
  language, the downloaded model with the lowest `errorRate` (or highest clarity); else the
  OS voice.
- Ratings come only from `bench/voices.py` → `bench/voices.json` → `bench/rate.py`: speed
  from real-time factor (≤0.05: 5, ≤0.15: 4, ≤0.3: 3, ≤0.6: 2), clarity from whisper
  character error rate averaged over tested languages (≤2%: 5, ≤5%: 4, ≤10%: 3, ≤20%: 2).
  Unmeasured models show "not rated". Recommended ones are listed first.

### 2.15 Tutorial and tips
- First launch: a 7-page tour (welcome + permissions with live status, translate, read
  aloud, translate and read, cards, live, offline models; last page links Ko-fi). Replay
  from the menu ("Show Tutorial") and Settings → General (which also re-arms the tips).
- One-time tips (HUD at the bottom, 7 s, never twice): first overlay, first reading, first
  card, first live session.

### 2.16 Support (Ko-fi: https://ko-fi.com/aadityavmore)
- Menu item "Support Lingveil on Ko-fi…", a ♥ Donate button in the Settings window's title
  bar (right), About credits, the tour's last page, and a card after an update ("Lingveil
  was updated to X").
- Reminder card (bottom-right, never takes focus): only after 30+ uses on 5+ different days
  and 14+ days after first use, shown 1.5 s after a translation closes or reading ends,
  then not again for 30 days. Buttons: Support on Ko-fi, Not Now, Don't show for 2 months
  (60 days).

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
