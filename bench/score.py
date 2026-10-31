"""chrF (character n-gram F-score, n=1..6, beta=2) of each engine's output against Google's.

usage: python3 bench/score.py            (reads bench/out/*.txt)
"""
import collections, glob, os, sys

def ngrams(s, n):
    s = s.replace(" ", "")
    return collections.Counter(s[i:i + n] for i in range(len(s) - n + 1))

def chrf(hyp, ref, beta=2.0):
    precs, recs = [], []
    for n in range(1, 7):
        h, r = ngrams(hyp, n), ngrams(ref, n)
        if not h or not r:
            continue
        match = sum((h & r).values())
        precs.append(match / sum(h.values()))
        recs.append(match / sum(r.values()))
    if not precs:
        return 0.0
    p, r = sum(precs) / len(precs), sum(recs) / len(recs)
    return 0.0 if p + r == 0 else (1 + beta**2) * p * r / (beta**2 * p + r) * 100

here = os.path.dirname(os.path.abspath(__file__))


def scores():
    """{engine: {target: mean chrF vs Google}} for every output in bench/out."""
    rows = collections.defaultdict(dict)
    for path in sorted(glob.glob(os.path.join(here, "out", "*.txt"))):
        name, tgt = os.path.basename(path)[:-4].rsplit("-", 1)
        if name == "google":
            continue
        ref = open(os.path.join(here, "out", f"google-{tgt}.txt"), encoding="utf-8").read().split("\n")
        hyp = open(path, encoding="utf-8").read().split("\n")
        rows[name][tgt] = sum(chrf(h, r) for h, r in zip(hyp, ref)) / len(ref)
    return rows


if __name__ == "__main__":
    rows = scores()
    print(f"{'engine':24} {'→en':>6} {'→hi':>6} {'→ja':>6} {'mean':>6}")
    for name, s in sorted(rows.items(), key=lambda kv: -sum(kv[1].values())):
        vals = [s.get(t) for t in ("en", "hi", "ja")]
        print(f"{name:24} " + " ".join(f"{v:6.1f}" if v is not None else "     -" for v in vals) + f" {sum(v for v in vals if v)/len([v for v in vals if v]):6.1f}")
