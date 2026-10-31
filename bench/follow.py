#!/usr/bin/env python3
"""Scores how well followed translations stay on their text while a window scrolls.

Run the harness first (debug listener action "harness"); it writes follow.log (where each
translated block was shown, over time) and follow.log.truth (where every line of text
really was, and the window's scroll offset over time). Error = shown position minus true
position of the block's text at the moment it was shown, after removing the constant
offset measured while the window is still.

usage: bench/follow.py <dir with follow.log>
"""
import bisect, statistics, sys

d = sys.argv[1]
lines, offs = [], []
VIEW_H = 592
for l in open(f"{d}/follow.log.truth", encoding="utf-8"):
    if l.startswith("line "):
        y, text = l[5:].rstrip("\n").split("\t", 1); lines.append((float(y), text))
    elif l.startswith("view "):
        VIEW_H = float(l.split()[1])
    elif l.startswith("offset "):
        _, t, o = l.split(); offs.append((float(t), float(o)))
ts = [t for t, _ in offs]

# The harness logs a scroll position when it sets it; the screen shows it at the next
# refresh, about a frame later.
DRAWN = 1 / 60

def offset(t):
    t -= DRAWN
    i = bisect.bisect_right(ts, t)
    if i == 0: return offs[0][1]
    if i >= len(offs): return offs[-1][1]
    (t0, o0), (t1, o1) = offs[i - 1], offs[i]
    return o0 + (o1 - o0) * (t - t0) / (t1 - t0)

def moving(t): return abs(offset(t) - offset(t - 0.25)) > 0.5

def where(text):
    key = " ".join(text.split())[:18]
    if len(key) < 8: return None   # fragments this short match the wrong line
    hits = [y for y, l in lines if key and key in " ".join(l.split())]
    return hits[0] if len(hits) == 1 else None   # skip text that appears more than once

events, cur = [], None
for l in open(f"{d}/follow.log", encoding="utf-8"):
    if l.startswith("shown "):
        cur = (float(l.split()[1]), []); events.append(cur)
    elif l.startswith("  ") and cur:
        y, h, text = l.strip("\n")[2:].split("\t", 2); cur[1].append((float(y), text, float(h)))

samples = []
for t, rows in events:
    o = offset(t)
    for y, text, _ in rows:
        ly = where(text)
        if ly is not None and -20 < y < VIEW_H: samples.append((t, y - (ly - o), moving(t)))
rest = [e for _, e, m in samples if not m]
base = statistics.median(rest) if rest else 0
def report(name, errs):
    errs = sorted(abs(e - base) for e in errs)
    if not errs: print(f"{name}: no samples"); return
    p = lambda q: errs[min(len(errs) - 1, int(q * len(errs)))]
    print(f"{name}: {len(errs)} samples, error median {p(.5):.1f} pt, 90% {p(.9):.1f} pt, max {errs[-1]:.1f} pt")
print(f"constant offset {base:.1f} pt; {len(events)} updates")
report("still ", [e for _, e, m in samples if not m])
report("moving", [e for _, e, m in samples if m])

if "-v" in sys.argv:
    t0 = offs[0][0]
    for t, rows in events:
        errs = [y - (where(x) - offset(t)) - base for y, x, _ in rows if where(x) is not None and -20 < y < VIEW_H]
        print(f"{t - t0:6.2f}s offset {offset(t):7.1f} blocks {len(rows):3d} matched {len(errs):3d} " +
              (f"err median {statistics.median(errs):7.1f} min {min(errs):7.1f} max {max(errs):7.1f}" if errs else ""))

# How long a line waits for its translation after it scrolls into view: a line counts as
# translated once a shown block covers it.
waits, never = [], 0
for y, l in lines:
    if len(l.strip()) < 12: continue
    entered = None
    for t, o in offs:
        inside = 0 <= y - o <= VIEW_H - 20
        if inside and entered is None: entered = t
        if not inside: entered = None
        if entered is not None and t - entered >= 1.5: break
    else:
        continue
    if entered is None or entered < events[0][0]: continue   # on screen before following began
    first = None
    for t, rows in events:
        if t < entered: continue
        o = offset(t)
        if any(top - 3 <= y - o + base <= top + h for top, _, h in rows): first = t; break
    if first: waits.append(first - entered)
    else: never += 1
if waits:
    waits.sort()
    print(f"new text: {len(waits)} lines, translated after median {waits[len(waits)//2]:.2f} s, 90% {waits[int(.9*len(waits))]:.2f} s "
          f"({never} lines never translated: code, tables and other text that is left as is)")

# Text scrolled back into view after it had been translated: how long until it shows again.
backs = []
def covered(y, t, rows): 
    o = offset(t)
    return any(top - 3 <= y - o + base <= top + h for top, _, h in rows)
for y, l in lines:
    if len(l.strip()) < 12: continue
    seen, out, back_at = False, False, None
    for t, rows in events:
        o = offset(t); inside = 8 <= y - o <= VIEW_H - 28
        if inside and covered(y, t, rows): seen = True
        if seen and not inside: out = True
        if out and inside and back_at is None: back_at = t
        if back_at is not None and covered(y, t, rows): backs.append(t - back_at); break
if backs:
    backs.sort()
    print(f"came back: {len(backs)} lines shown again after median {backs[len(backs)//2]*1000:.0f} ms, 90% {backs[int(.9*len(backs))]*1000:.0f} ms")
