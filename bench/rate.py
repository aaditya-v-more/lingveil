"""Turns measured benchmark results into the 1-5 ratings shown in Settings > Models and Voices.

Ratings come only from numbers, with fixed thresholds, so they can be re-derived by anyone:
  accuracy: mean chrF vs Google over ->en, ->hi, ->ja   (>=75: 5, >=72: 4, >=68: 3, >=64: 2, else 1)
  speed:    mean warm milliseconds per line             (<=90: 5, <=130: 4, <=200: 3, <=400: 2, else 1)
Models with both measurements are marked tested; the rest keep their estimates.

usage: python3 bench/rate.py            (updates shared/models.json and prints the table)
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import scores  # noqa: E402

here = os.path.dirname(os.path.abspath(__file__))
times = json.load(open(os.path.join(here, "times.json"), encoding="utf-8"))
chrf = scores()

def stars(value, steps, higher_is_better):
    for i, s in enumerate(steps):
        if (value >= s) if higher_is_better else (value <= s):
            return 5 - i
    return 1

path = os.path.join(here, "..", "shared", "models.json")
catalog = json.load(open(path, encoding="utf-8"))
print(f"{'model':22} {'ms/line':>8} {'chrF':>6}  speed accuracy")
rated = {}
for name, sets in times.items():
    if name == "about" or name not in chrf:
        continue
    ms = sum(t / n for t, n in sets.values()) / len(sets)
    acc = sum(chrf[name].values()) / len(chrf[name])
    s, a = stars(ms, [90, 130, 200, 400], False), stars(acc, [75, 72, 68, 64], True)
    rated[name] = (s, a)
    print(f"{name:22} {ms:8.0f} {acc:6.1f}  {s:5} {a:8}")
for m in catalog["models"]:
    if m["id"] in rated:
        m["speed"], m["accuracy"] = rated[m["id"]]
        m["tested"] = True
catalog.setdefault("appleRatings", {})["highQuality"] = dict(zip(("speed", "accuracy"), rated.get("apple", (0, 0))))
json.dump(catalog, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

# Voices (bench/voices.py): speed from real-time factor, clarity from transcription error.
#   speed:   RTF <=0.05: 5, <=0.15: 4, <=0.3: 3, <=0.6: 2, else 1
#   clarity: mean CER over the voice's tested languages <=2%: 5, <=5%: 4, <=10%: 3, <=20%: 2, else 1
vpath = os.path.join(here, "voices.json")
if os.path.exists(vpath):
    vres = json.load(open(vpath, encoding="utf-8"))
    vcat_path = os.path.join(here, "..", "shared", "voices.json")
    vcat = json.load(open(vcat_path, encoding="utf-8"))
    def vrate(langs):
        rtf = sum(r["rtf"] for r in langs.values()) / len(langs)
        cer = sum(r["cer"] for r in langs.values()) / len(langs)
        return stars(rtf, [0.05, 0.15, 0.3, 0.6], False), stars(cer, [0.02, 0.05, 0.10, 0.20], False), rtf, cer
    print(f"\n{'voice':44} {'RTF':>5} {'CER':>6}  speed clarity")
    ratings = {}
    for name, langs in vres.items():
        s_, c_, rtf, cer = vrate(langs)
        ratings[name] = {"speed": s_, "clarity": c_}
        print(f"{name:44} {rtf:5.2f} {cer*100:5.1f}%  {s_:5} {c_:7}")
    for m in vcat["models"]:
        if m["id"] in ratings:
            m.update(ratings[m["id"]]); m["tested"] = True
            # Per-language error rate, so the app picks the clearest voice for each language.
            m["errorRate"] = {l: round(r["cer"], 3) for l, r in vres[m["id"]].items()}
    vcat["builtInRatings"] = {k: v for k, v in ratings.items() if k in ("apple", "google")}
    json.dump(vcat, open(vcat_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
