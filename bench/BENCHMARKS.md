# Translation engine benchmarks

These numbers set the speed and accuracy ratings shown in **Settings → Models**. Only
the models under "Recommended" were measured here; ratings in "More models" are estimates
from the makers' published results and model size.

## Setup

- MacBook Air, Apple silicon, 24 GB, macOS 27.0.1. The Air has no fan, so long runs slow
  down as it warms up; warm numbers vary by about ±30 %.
- Local models run through the bundled llama.cpp server (Metal, 4 parallel slots, Q4
  weights), one request per line, exactly as the app runs them.
- Test text (`to-en.txt`, `from-en.txt`): real app and chat strings, from one-word labels
  to two-sentence notices.
  - Into English: 32 lines of Japanese, Spanish, Chinese, Korean and German.
  - Out of English: 20 lines into Hindi and into Japanese.
- Accuracy: chrF (character n-gram F-score) against Google Translate's output, then a read
  of every output. chrF against one reference undersells natural wording that differs from
  Google's choices (Index-Translate's everyday Hindi "बदलाव", "डिलीट" vs Google's "परिवर्तन").

## Results

Warm time is the second pass over each set (model already loaded). First use adds the
model load, about 2–6 s (longer for the 7B+ models). Runs from 31 Oct 2026; the Air was
also downloading models in the background, so the larger models' times are on the slow side.

| Engine | Download | Warm time, 20–32 lines | chrF →en | chrF →hi | chrF →ja | Notes |
|---|---|---|---|---|---|---|
| Google Translate (online) | — | 0.1–0.5 s | reference | reference | reference | |
| Gemma 4 E2B (Q4_0) | 2.84 GB | 2.5–4.0 s | 80.7 | 70.4 | 76.5 | Best overall, especially into Hindi |
| Gemma 4 E4B (Q4_0) | 4.59 GB | 5.6–9.6 s | 81.9 | 68.8 | 75.9 | No better than E2B, half the speed |
| Index-Translate 9B (Q4_K_M) | 5.78 GB | 8.4–12.8 s | 79.0 | 65.2 | 77.9 | Second-best overall; 3–4× slower than the 2B |
| Hy-MT2 7B (Q4_K_M) | 4.62 GB | 11–31 s | 80.8 | 58.4 | 80.2 | Best into Japanese; slow on an Air |
| Apple Translation, high quality | built in | 5.4–7.4 s | 80.6 | 61.9 | 76.2 | Good, but slow for whole screens |
| Index-Translate 2B (Q4_K_M) | 1.31 GB | 2.1–3.2 s | 80.6 | 52.6 | 74.0 | Natural everyday wording; reads close to Gemma |
| TranslateGemma 12B (Q4_K_M) | 7.30 GB | 24–28 s | 81.6 | 50.6 | 75.6 | Slowest; weak into Hindi |
| TranslateGemma 4B (Q4_K_M) | 2.49 GB | 6.9–12.9 s | 78.8 | 58.8 | 69.0 | Slowest small model |
| Hy-MT2 1.8B (Q4_K_M) | 1.13 GB | 1.6–2.6 s | 76.0 | 48.2 | 68.3 | Fastest; literal, a few wrong Hindi words |

Ratings are computed, not chosen: `bench/rate.py` turns the measurements into 1–5 stars
with fixed thresholds and writes them to `shared/models.json`.
- Accuracy from mean chrF: ≥ 75 → 5, ≥ 72 → 4, ≥ 68 → 3, ≥ 64 → 2, else 1.
- Speed from warm ms per line: ≤ 90 → 5, ≤ 130 → 4, ≤ 200 → 3, ≤ 400 → 2, else 1.

Current result: Gemma 4 E2B 3 / 5, Gemma 4 E4B 2 / 5, Index-Translate 9B 1 / 4, Hy-MT2 7B 1 / 4,
Apple high quality 2 / 4, Index-Translate 2B 4 / 3, TranslateGemma 12B 1 / 3, TranslateGemma 4B
1 / 3, Hy-MT2 1.8B 5 / 2 (speed / accuracy). The "Fastest", "Best balance" and "Most accurate"
labels on the three recommended models are recommendations, not measurements. Hy-MT2 30B-A3B
keeps an estimate (it needs a 32 GB Mac) and Apple's fast models are not rated until measured.

On Windows (RTX 3060 laptop, Vulkan) Hy-MT2 1.8B measured 2.2–2.9 s warm and chrF 75.3 / 48.1
(→en / →hi), the same range as the Mac.

A full text-heavy screen (about 100 blocks, mostly long English paragraphs, into Hindi)
takes about 30 s with Index-Translate 2B on this Mac, painted progressively starting with
the front window; Google does the same screen in under a second.

## Staying on the text while scrolling

The debug action `harness` opens a test window behind all others that scrolls itself
(slow scroll, a fast flick, scrolling back) and logs where every line really is; Lingveil
follows it with an invisible overlay and logs where it shows each translated block.
`python3 bench/follow.py <debug dir>` compares them. `Lingveil --follow-bench <log>` runs the
same thing without the menu bar app, and `LINGVEIL_HARNESS_SIZE=1500x950` tries a bigger
window. A 760×620 pt window of README/SPEC
text, Google, Apple silicon, several runs:

| | Typical | 90% of samples |
|---|---|---|
| Position error while still | 0.3–1 pt | 2–4 pt |
| Position error while scrolling (up to ~1300 pt/s) | 2–3 pt | 7–17 pt |
| New text translated after it scrolls into view | 1.2–1.5 s | 2.5–2.9 s |
| Text scrolled back into view shown again | 15–170 ms | 1–1.5 s |

Reading only the strips that are new takes 35–250 ms instead of 300–1000 ms for the window;
most of the wait for new text is now the translation request itself (120–600 ms to Google).
At 1500×950 pt (about a full laptop window) following a frame takes 8 ms (3 ms at
760×620), and the error while scrolling is median 3.8 pt, 90% 15 pt. Since reading and translating wait until the screen stops (60 ms without a new frame),
nothing but moving blocks happens on the main thread while scrolling: the longest gap
between a frame and its move went from 27–37 ms to 1 ms, and the error while scrolling to
90% 10–14 pt (760×620) and 6 pt (1500×950). During a flick (~8000 pt/s) blocks are hidden until the window settles. Text seen before
comes back instantly from the translation cache.

## Text recognition on screen text

`bench/ocr/ocrbench.swift <text> [width height font]` renders text like a Retina window and
times each recognizer macOS has, with character error rate against the real text
(760×590 pt, Apple silicon, best of 3):

| | English 14 pt | English 12 pt | English 11 pt | Japanese 14 pt | Hindi 14 pt |
|---|---|---|---|---|---|
| Vision accurate (used) | 160 ms, 7.8%* | 400–610 ms, 1.4% | 660 ms, 3.5% | 1.6–2.7 s, 3.0% | 540 ms, 0.0% |
| Vision accurate, language given | 145 ms | 435 ms, 2.4% | 470 ms, 4.1% | | |
| Vision fast | 30 ms, 3.8% | 60–110 ms, 5.8% | 130 ms, 6.7% | 100% (can't) | 99% (can't) |
| Live Text (VisionKit) | 270 ms, 7.7% | | | 1.2 s, 3.0% | 300 ms, 0.0% |
| 2–6 tiles in parallel | slower | | | no gain | |

\* differences from line order in the markdown sample, not misread letters.
Recognition cost grows with the area read, so reading only what's new is the speed-up.

## Read-aloud voices

`bench/voices.py` speaks the six sentences in `bench/speak/<lang>.txt` with each voice,
then transcribes the audio with whisper.cpp (large-v3-turbo). Speed is the real-time
factor (time to make the audio ÷ its length); clarity is the character error rate of the
transcript against the text. Apple M-series, 4 threads, sherpa-onnx 1.13.8.

| Voice | English RTF / error | Hindi | Japanese | Memory |
|---|---|---|---|---|
| Google (sfg, google-tts-local) | 0.02 / 0% | — | — | — |
| Apple (Daniel Enhanced, Lekha) | 0.12 / 1.3% | 0.10 / 18.8% | — | — |
| Supertonic 3 | 0.14 / 0% | 0.14 / 14.4% | 0.14 / 2.4% | ~370 MB |
| Kokoro (int8) | 0.58 / 1.3% | 0.55 / 15.9% | 0.67 / 69.8%\* | ~550 MB |
| Piper Hindi (Rohan) | — | 0.14 / 6.5% | — | ~150 MB |
| Piper English (Amy) | 0.09 / 1.3% | — | — | ~135 MB |
| Kitten Nano | 0.18 / 0% | — | — | ~190 MB |

\* Kokoro's Japanese came back mostly wrong, so Japanese is not offered for it.

```sh
python3 bench/voices.py --whisper <ggml model>   # writes bench/voices.json
python3 bench/rate.py                            # writes the ratings into shared/voices.json
```

## Running it

```sh
ARCHS=arm64 ./build.sh
bench/run.sh google                       # reference translations
bench/run.sh apple
bench/run.sh local index-translate-2b     # any id from LocalModel.catalog
python3 bench/score.py
```

Models are read from `~/Library/Application Support/Lingveil/Models`; download them from
Settings → Models first.
