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
model load, about 2–6 s.

| Engine | Download | Warm time, 20–32 lines | chrF →en | chrF →hi | chrF →ja | Notes |
|---|---|---|---|---|---|---|
| Google Translate (online) | — | 0.1–0.5 s | reference | reference | reference | |
| Hy-MT2 1.8B (Q4_K_M) | 1.13 GB | 1.5–3.0 s | 75.3 | 47.9 | 67.7 | Literal; a few invented or wrong words into Hindi |
| Index-Translate 2B (Q4_K_M) | 1.31 GB | 1.9–3.4 s | 80.6 | 52.6 | 74.0 | Natural everyday wording; very close to Gemma when read |
| Gemma 4 E2B (Q4_0) | 2.84 GB | 2.5–3.9 s | 80.7 | 70.4 | 76.5 | Best overall, especially into Hindi |
| Apple Translation, high quality | built in | 5.4–7.4 s | 80.6 | 61.9 | 76.2 | Good, but slow for whole screens |

Ratings derived from this: Hy-MT2 1.8B speed 5 / accuracy 3 ("Fastest"), Index-Translate 2B
4 / 4 ("Best balance", the default local model), Gemma 4 E2B 3 / 5 ("Most accurate"),
Apple high quality 1 / 4. Apple's fast models need a per-pair download through macOS and
are shown as not rated yet.

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
