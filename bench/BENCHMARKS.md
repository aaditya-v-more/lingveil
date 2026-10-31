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
