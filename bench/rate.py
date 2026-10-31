"""Turns measured benchmark results into the 1-5 ratings shown in Settings > Models.

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
