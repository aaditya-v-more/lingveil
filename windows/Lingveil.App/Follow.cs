using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Lingveil.Core;

namespace Lingveil.App;

/// Keeps a translation in the app while you scroll, click and type (shared/SPEC.md §2.12b).
/// A capture loop on its own thread grabs the followed area up to 60 times a second and
/// keeps only frames that changed; how far each part moved is measured on one brightness
/// sample per point, translated blocks move with their text at once, blocks whose text
/// went away are hidden, and when the screen is still again whatever isn't followed yet is
/// read and translated. Text that scrolls back is recognized from memory.
public sealed class Follower
{
    readonly OverlayWindow window;
    readonly Int32Rect area;      // physical pixels
    readonly double scale;
    public MotionTracker Tracker { get; }
    Thread? thread;
    volatile bool running;
    DateTime lastChange = DateTime.MinValue;
    bool dirty;
    DispatcherTimer? loop, settle;
    double[] exact = [], previous = [];
    HashSet<int> hidden = [];
    double previousTime;
    int reading;
    int shownSequence = -1;   // the frame the blocks on screen were read from
    /// What is being followed: the translated blocks, then areas already read that need no
    /// translation (code, numbers, images without text), all as of the current reference.
    List<Block> blocks = [];
    List<Rect> known = [];
    /// What each followed block's original text looked like, and blocks that scrolled away,
    /// kept with that picture, to put back at once when their text scrolls back.
    public sealed record Look(byte[] Pixels, int W, int H, Rect Rect, float[] Rows, float Contrast);
    List<Look?> looks = [];
    List<(Block Block, Look Look)> memory = [];
    DateTime lastFullRead = DateTime.UtcNow, lastRecall = DateTime.MinValue, lastUiStill = DateTime.MinValue;
    bool recalling, partialSinceFull;
    static readonly double StillAfter = 0.06;
    static readonly double DrawLead = 0.004;
    public Action<bool>? OnBusy;
    public bool Running => running;
    readonly Stopwatch clock = Stopwatch.StartNew();
    double Now => clock.Elapsed.TotalSeconds;

    public Follower(OverlayWindow window, Native.Monitor mon, Int32Rect area)
    {
        this.window = window; this.area = area; scale = mon.Scale;
        Tracker = new MotionTracker(scale);
    }

    /// Starts watching and returns once the first frame is in.
    public async Task Start()
    {
        running = true;
        thread = new Thread(CaptureLoop) { IsBackground = true, Priority = ThreadPriority.AboveNormal, Name = "Lingveil follow" };
        thread.Start();
        for (int i = 0; i < 40 && !Tracker.HasFrame; i++) await Task.Delay(25);
        dirty = true;   // the first frame may have arrived before this was running
        loop = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromMilliseconds(30) };
        loop.Tick += (_, _) => Refresh();
        loop.Start();
        Prefetch();
    }

    public void Stop()
    {
        running = false;
        loop?.Stop(); loop = null;
        settle?.Stop(); settle = null;
        Tracker.Reset();
    }

    /// Tests: while the debug listener photographs the screen with our overlay in it.
    public static volatile bool Paused;

    void CaptureLoop()
    {
        var ui = window.Dispatcher;
        while (running)
        {
            double t0 = Now;
            if (Paused) { Thread.Sleep(16); continue; }
            try
            {
                var px = Native.Capture(area);
                double shown = Now;
                var m = Tracker.Frame(px, shown);
                if (m != null) ui.BeginInvoke(() => Changed(m));
            }
            catch (Exception e) { Debug.Log("follow capture " + e.Message); }
            // Up to 60 frames a second.
            int wait = (int)Math.Max(1, 16 - (Now - t0) * 1000);
            Thread.Sleep(wait);
        }
    }

    /// Shows `fresh`, read from frame `token`. If the screen has moved since, they are moved
    /// to where their text is now before they appear.
    public bool Adopt(List<Block> fresh, List<Rect> knownNow, MotionTracker.Token token)
    {
        if (!running) return false;
        var rects = fresh.Select(b => b.Item.Rect).ToList();
        if (!Tracker.SetReference(token, [.. rects, .. knownNow], out var catchUp)) return false;
        // Blocks that are going away keep their look, to come back if their text does.
        var staying = fresh.Select(b => b.Item.Text).ToHashSet();
        for (int i = 0; i < blocks.Count; i++)
        {
            if (staying.Contains(blocks[i].Item.Text) || i >= looks.Count || looks[i] is not { } l) continue;
            memory.RemoveAll(m => m.Block.Item.Text == blocks[i].Item.Text);
            memory.Add((blocks[i], l));
        }
        if (memory.Count > 300) memory.RemoveRange(0, memory.Count - 300);
        looks = rects.Select(r => LookAt(token, r)).ToList();
        blocks = fresh; known = knownNow;
        previous = []; previousTime = 0;
        if (catchUp is { Shifts: { } sh })
        {
            exact = sh.Take(fresh.Count).Select(s => (double)s).ToArray();
            hidden = catchUp.Hidden.Where(i => i < fresh.Count).ToHashSet();
            window.View.Show(fresh, exact, hidden);
        }
        else
        {
            exact = []; hidden = [];
            window.View.Blocks = fresh;
            dirty = false;
        }
        return true;
    }

    /// A block's pixels in frame `token` (points), if it's wholly in view.
    static Look? LookAt(MotionTracker.Token t, Rect r)
    {
        int x0 = (int)Math.Round(r.X), y0 = (int)Math.Round(r.Y), w = (int)Math.Round(r.Width), h = (int)Math.Round(r.Height);
        if (x0 < 0 || y0 < 0 || w < 8 || h < 6 || x0 + w >= t.W || y0 + h > t.H) return null;
        var px = new byte[w * h];
        for (int y = 0; y < h; y++) Array.Copy(t.Luma, (y0 + y) * t.W + x0, px, y * w, w);
        var rows = new float[h];
        for (int y = 0; y < h; y++) { int e = 0; for (int x = 0; x < w - 1; x++) e += Math.Abs(px[y * w + x + 1] - px[y * w + x]); rows[y] = e; }
        int mean = (int)(px.Sum(b => (long)b) / px.Length);
        float contrast = px.Sum(b => (float)Math.Abs(b - mean)) / px.Length;
        if (contrast <= 3) return null;
        return new Look(px, w, h, new Rect(x0, y0, w, h), rows, contrast);
    }

    /// Remembered blocks whose text is back in view inside `strips` of frame `token`, placed
    /// where it is now: each picture slides up and down over the strip at its own x (row
    /// profiles first, then the pixels at the best three spots) and must match closely.
    static List<(int, Block)> Recall(List<Rect> strips, MotionTracker.Token t, List<(Block Block, Look Look)> mem)
    {
        var found = new List<(int, Block)>();
        var rowCache = new Dictionary<long, float>();
        var l = t.Luma; int lw = t.W;
        for (int k = mem.Count - 1; k >= 0; k--)
        {
            var lk = mem[k].Look;
            var strip = strips.FirstOrDefault(s => s.Left <= lk.Rect.Left + 4 && s.Right >= lk.Rect.Right - 4);
            if (strip.IsEmpty || strip.Width == 0) continue;
            int lo = Math.Max(0, (int)strip.Top - lk.H / 3), hi = Math.Min(t.H - lk.H, (int)strip.Bottom - lk.H * 2 / 3);
            if (lo > hi) continue;
            int x0 = (int)lk.Rect.Left;
            float RowEnergy(int y)
            {
                long key = ((long)y << 32) | ((long)x0 << 16) | (uint)lk.W;
                if (rowCache.TryGetValue(key, out var v)) return v;
                int e = 0;
                for (int x = x0; x < x0 + lk.W - 1; x++) e += Math.Abs(l[y * lw + x + 1] - l[y * lw + x]);
                return rowCache[key] = e;
            }
            float energy = Math.Max(1, lk.Rows.Sum());
            var cands = new List<(float, int)>();
            for (int y = lo; y <= hi; y++)
            {
                float d = 0;
                for (int r = 0; r < lk.H; r++) d += Math.Abs(lk.Rows[r] - RowEnergy(y + r));
                cands.Add((d / energy, y));
            }
            foreach (var (pd, y) in cands.OrderBy(c => c.Item1).Take(3))
            {
                if (pd >= 0.25) break;
                long diff = 0; int n = 0;
                for (int r = 0; r < lk.H; r++)
                    for (int x = 0; x < lk.W; x += 2) { diff += Math.Abs(lk.Pixels[r * lk.W + x] - l[(y + r) * lw + x0 + x]); n++; }
                if ((float)diff / Math.Max(1, n) / Math.Max(lk.Contrast, 4) < 0.15)
                {
                    var b = mem[k].Block;
                    var item = b.Item; item.Rect = new Rect(lk.Rect.X, y, lk.Rect.Width, lk.Rect.Height);
                    found.Add((k, b with { Item = item }));
                    break;
                }
            }
        }
        return found;
    }

    /// What is followed now, moved to where it is in frame `token`.
    (List<Block>, List<Rect>) Carried(MotionTracker.Token t)
    {
        var kept = new List<Block>(); var keptKnown = new List<Rect>();
        for (int i = 0; i < blocks.Count; i++)
        {
            if (i >= t.Shifts.Length || t.Hidden.Contains(i)) continue;
            var item = blocks[i].Item; var r = item.Rect; r.Offset(0, t.Shifts[i]); item.Rect = r;
            kept.Add(blocks[i] with { Item = item });
        }
        for (int k = 0; k < known.Count; k++)
        {
            int i = blocks.Count + k;
            if (i >= t.Shifts.Length || t.Hidden.Contains(i)) continue;
            var r = known[k]; r.Offset(0, t.Shifts[i]); keptKnown.Add(r);
        }
        return (kept, keptKnown);
    }

    /// Areas of `items` that were read but produced no block (left as is): followed too, so
    /// they aren't read again.
    public static List<Rect> Untranslated(IEnumerable<TextItem> items, IReadOnlyList<Block> fresh) =>
        items.Where(it =>
        {
            double a = it.Rect.Width * it.Rect.Height;
            return !fresh.Any(b => { var o = Rect.Intersect(b.Item.Rect, it.Rect); return !o.IsEmpty && o.Width * o.Height > a * 0.7; });
        }).Select(it => it.Rect).ToList();

    /// Reads several strips of `snap` (points) in one go: stacked into one image, 24 px
    /// apart and padded with each row's last pixel, since each separate request has a fixed cost.
    static async Task<List<TextItem>> Read(List<Rect> strips, Snapshot snap)
    {
        double s = snap.Scale; const int gap = 24;
        var src = snap.Pixels;
        var px = strips.Select(r =>
        {
            int x0 = Math.Max(0, (int)Math.Floor(r.X * s)), y0 = Math.Max(0, (int)Math.Floor(r.Y * s));
            int x1 = Math.Min(src.Width, (int)Math.Ceiling(r.Right * s)), y1 = Math.Min(src.Height, (int)Math.Ceiling(r.Bottom * s));
            return new Int32Rect(x0, y0, x1 - x0, y1 - y0);
        }).Where(r => r.Width >= 8 && r.Height >= 8).ToList();
        if (px.Count == 0) return [];
        int W = px.Max(r => r.Width), H = px.Sum(r => r.Height) + gap * (px.Count - 1);
        using var outp = new PixelBuffer(W, H);
        var offsets = new List<int>();
        int yy = 0;
        unsafe
        {
            byte* dst0 = (byte*)outp.Base, src0 = (byte*)src.Base;
            for (int k = 0; k < px.Count; k++)
            {
                var r = px[k];
                offsets.Add(yy);
                for (int row = 0; row < r.Height; row++)
                {
                    byte* d = dst0 + (yy + row) * outp.Stride;
                    Buffer.MemoryCopy(src0 + (r.Y + row) * src.Stride + r.X * 4, d, r.Width * 4, r.Width * 4);
                    // Pad to the full width with the row's last pixel (blends in, adds no edges).
                    for (int x = r.Width; x < W; x++) *(uint*)(d + x * 4) = *(uint*)(d + (r.Width - 1) * 4);
                }
                yy += r.Height;
                if (k < px.Count - 1)
                {
                    for (int row = 0; row < gap; row++) Buffer.MemoryCopy(dst0 + (yy - 1) * outp.Stride, dst0 + (yy + row) * outp.Stride, outp.Stride, outp.Stride);
                    yy += gap;
                }
            }
        }
        var found = await Ocr.Recognize(outp, 7 * s);
        var lines = new List<TextItem>();
        foreach (var line in found)
        {
            double cy = line.Rect.Y + line.Rect.Height / 2;
            int k = offsets.FindLastIndex(o => o <= cy);
            if (k < 0 || cy >= offsets[k] + px[k].Height) continue;
            var r = new Rect((px[k].X + line.Rect.X) / s, (px[k].Y + line.Rect.Y - offsets[k]) / s, line.Rect.Width / s, line.Rect.Height / s);
            lines.Add(new TextItem(line.Text, r, 1));
        }
        return Pipeline.EstimateSizes(Ocr.Paragraphs(lines));
    }

    void Changed(MotionTracker.Motion m)
    {
        if (!running) return;
        lastChange = DateTime.UtcNow;
        dirty = true;
        if (m.Shifts != null && m.Reference == Tracker.ReferenceId) Apply(m, predict: true);
    }

    /// Moves the blocks to the measured positions. The frame is already a little old by the
    /// time the overlay is shown, so blocks are put a little further along their way (speed ×
    /// frame age); when frames stop coming for 45 ms they settle on the measured spot.
    void Apply(MotionTracker.Motion m, bool predict)
    {
        if (m.Shifts == null) return;
        var now = m.Shifts.Take(blocks.Count).Select(s => (double)s).ToArray();
        var hide = m.Hidden.Where(i => i < blocks.Count).ToHashSet();
        var shown = (double[])now.Clone();
        double dt = m.Time - previousTime;
        if (previous.Length == now.Length && dt > 0.004 && dt < 0.1)
        {
            double lead = Math.Min(0.06, Math.Max(0, Now - m.Time + DrawLead));
            for (int i = 0; i < now.Length; i++)
            {
                if (hide.Contains(i)) continue;
                double v = (now[i] - previous[i]) / dt;
                if (predict) shown[i] += Math.Clamp(v * lead, -250, 250);
            }
        }
        previous = now; previousTime = m.Time; exact = now; hidden = hide;
        window.View.Move(shown, hide);
        if (now.Length > 0)
        {
            Debug.Log($"follow moved {now.Min():0}…{now.Max():0} pt, {hide.Count}/{now.Length} hidden, frame {(Now - m.Time) * 1000:0} ms old; bands {Tracker.DebugBands}");
        }
        settle?.Stop();
        if (!shown.SequenceEqual(now))
        {
            settle = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(45) };
            settle.Tick += (_, _) => { settle?.Stop(); if (running && exact.Length == now.Length) window.View.Move(exact, hidden); };
            settle.Start();
        }
    }

    bool Still => (DateTime.UtcNow - lastChange).TotalSeconds > StillAfter;

    async Task WhenStill() { while (running && !Still) await Task.Delay(8); }

    /// Reads and translates whatever is new, as soon as the screen stops moving. While it
    /// moves nothing is read, recalled or added. Only what isn't followed yet is read; after a
    /// second of stillness following partial reads, the whole area is read once more with UI
    /// Automation (exact text).
    void Refresh()
    {
        if (!running || !Still) return;
        double stillFor = (DateTime.UtcNow - lastChange).TotalSeconds;
        bool polish = !dirty && partialSinceFull && stillFor > 1.0 && (DateTime.UtcNow - lastFullRead).TotalSeconds > 1.0;
        if (!dirty && !polish) return;

        // Text back in view that was translated before: put it back without reading it.
        if (dirty && !polish && !recalling && memory.Count > 0 && shownSequence >= 0 && (DateTime.UtcNow - lastRecall).TotalSeconds > 0.08
            && Tracker.Begin(copyPixels: false) is { } rt && rt.Reference == Tracker.ReferenceId)
        {
            lastRecall = DateTime.UtcNow;
            recalling = true;
            var unread = Unread(rt, edges: true);
            var mem = memory.ToList();
            _ = Task.Run(() => Recall(unread, rt, mem)).ContinueWith(async task =>
            {
                var back = task.Result;
                await WhenStill();
                recalling = false;
                if (back.Count == 0 || !running || rt.Reference != Tracker.ReferenceId || rt.Sequence <= shownSequence) return;
                var (kept, keptKnown) = Carried(rt);
                var ids = back.Select(b => b.Item1).ToHashSet();
                memory = memory.Where((_, i) => !ids.Contains(i) || i >= mem.Count).ToList();
                if (Adopt([.. kept, .. back.Select(b => b.Item2)], keptKnown, rt))
                {
                    shownSequence = rt.Sequence;
                    dirty = true;   // read whatever is still unread
                    Debug.Log($"follow recalled {back.Count} blocks");
                }
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        if (reading > 0) return;
        dirty = false;
        if (Tracker.Begin(copyPixels: true) is not { Pixels: { } pixels } token) { Debug.Log("follow: no frame to read"); return; }
        var snap = new Snapshot(pixels, scale);
        // Read only what's new, unless nothing is followed yet, it's time for the full read,
        // or most of the area is new anyway.
        List<Rect>? strips = null;
        if (!polish && shownSequence >= 0 && token.Reference == Tracker.ReferenceId)
        {
            strips = Unread(token, edges: false);
            double areaPts = area.Width / scale * (area.Height / scale), unread = strips.Sum(r => r.Width * r.Height);
            Debug.Log($"follow unread {strips.Count} strips, {unread / areaPts:P0} of the area");
            if (unread > areaPts * 0.6) strips = null;
        }
        if (strips is { Count: 0 }) { snap.Dispose(); return; }   // everything in view is already followed
        bool full = strips == null;
        reading++;
        OnBusy?.Invoke(true);
        _ = Work();

        async Task Work()
        {
            var sw = Stopwatch.StartNew();
            try
            {
                var target = Settings.Current.TargetLanguage;
                List<TextItem> items;
                if (strips != null) items = await Task.Run(() => Read(strips, snap));
                else
                {
                    var a = area; var sc = scale;
                    items = await Task.Run(() => Pipeline.Items(snap, Settings.Current.UseAccessibility ? () => Uia.Items(a, sc) : null));
                }
                long ocrMs = sw.ElapsedMilliseconds;
                List<Block> fresh;
                try { fresh = await Task.Run(() => Pipeline.Blocks(items, snap, target)); }
                catch (Exception e) { Debug.Log($"follow refresh failed: {e.Message} ({items.Count} items)"); return; }
                // Scrolling started again while this was read: keep it until it stops, then
                // show it where its text is by then.
                await WhenStill();
                if (!running || token.Sequence <= shownSequence) return;
                var newKnown = Untranslated(items, fresh);
                // Strips with nothing readable in them (pictures, icons) are known too.
                if (strips != null) newKnown.AddRange(strips.Where(r => !items.Any(i => i.Rect.IntersectsWith(r))));
                var all = fresh.ToList(); var allKnown = newKnown;
                if (!full)
                {
                    // Keep everything already followed, moved to where it is in this frame.
                    if (token.Reference != Tracker.ReferenceId) { dirty = true; return; }
                    var (kept, keptKnown) = Carried(token);
                    foreach (var moved in kept)
                    {
                        var mr = moved.Item.Rect;
                        if (!fresh.Any(f => { var o = Rect.Intersect(f.Item.Rect, mr); return !o.IsEmpty && o.Width * o.Height > mr.Width * mr.Height * 0.3; })) all.Add(moved);
                    }
                    allKnown.AddRange(keptKnown);
                }
                Debug.Log($"follow {fresh.Count} new blocks ({all.Count - fresh.Count} kept) from {(strips != null ? $"{strips.Count} strips, {(int)strips.Sum(r => r.Height)} pt tall" : "whole area")} in {sw.ElapsedMilliseconds} ms (reading {ocrMs})");
                if (Adopt(all, allKnown, token))
                {
                    shownSequence = token.Sequence;
                    if (full) { lastFullRead = DateTime.UtcNow; partialSinceFull = false; } else partialSinceFull = true;
                }
                else dirty = true;
            }
            catch (Exception e) { Debug.Log("follow error " + e); }
            finally
            {
                snap.Dispose();
                reading--;
                OnBusy?.Invoke(reading > 0);
            }
        }
    }

    /// The parts of frame `token` with something on them that nothing followed covers:
    /// horizontal strips (points) to read. A grid of 32×8 pt cells; a cell needs reading if it
    /// has edges (≥ 4 brightness steps > 28). `edges`: leave out text cut by the top and
    /// bottom edges while scrolling; it will be whole in a moment.
    List<Rect> Unread(MotionTracker.Token t, bool edges)
    {
        int w = t.W, h = t.H, cw = 32, ch = 8;
        int cols = (w + cw - 1) / cw, rows = (h + ch - 1) / ch;
        var covered = new bool[cols * rows];
        var rects = blocks.Select(b => b.Item.Rect).Concat(known).ToList();
        for (int i = 0; i < rects.Count; i++)
        {
            if (i >= t.Shifts.Length || t.Hidden.Contains(i)) continue;
            var m = rects[i]; m.Offset(0, t.Shifts[i]); m.Inflate(3, 3);
            int c0 = Math.Max(0, (int)m.Left / cw), c1 = Math.Min(cols - 1, (int)m.Right / cw);
            int r0 = Math.Max(0, (int)m.Top / ch), r1 = Math.Min(rows - 1, (int)m.Bottom / ch);
            for (int rr = r0; rr <= r1; rr++)
            {
                double cy = rr * ch + ch / 2.0;
                if (cy < m.Top || cy > m.Bottom) continue;
                for (int cc = c0; cc <= c1; cc++) { double cx = cc * cw + cw / 2.0; if (cx >= m.Left && cx <= m.Right) covered[rr * cols + cc] = true; }
            }
        }
        var need = new bool[cols * rows];
        var l = t.Luma;
        for (int rr = 0; rr < rows; rr++)
        {
            if (edges && (rr * ch < 10 || (rr + 1) * ch > h - 10)) continue;
            for (int cc = 0; cc < cols; cc++)
            {
                if (covered[rr * cols + cc]) continue;
                int busy = 0, y1 = Math.Min(h, rr * ch + ch), x1 = Math.Min(w - 1, cc * cw + cw);
                for (int y = rr * ch; y < y1; y += 2)
                    for (int x = cc * cw; x < x1; x++) if (Math.Abs(l[y * w + x + 1] - l[y * w + x]) > 28) busy++;
                need[rr * cols + cc] = busy >= 4;
            }
        }
        // Rows of needed cells, joined into strips (one empty row may sit between). Within a
        // row, cells more than three apart start separate strips: Windows shows scroll bars
        // all the time, and a scroll bar's column would otherwise join every row's text into
        // one strip as wide and tall as the window.
        var strips = new List<Rect>();
        var open = new List<(int C0, int C1, int R0, int R1)>();
        void Close((int C0, int C1, int R0, int R1) o)
        {
            double x0 = Math.Max(0, o.C0 * cw - 8), y0 = Math.Max(0, o.R0 * ch - 4);
            double x1 = Math.Min(w, (o.C1 + 1) * cw + 8), y1 = Math.Min(h, (o.R1 + 1) * ch + 4);
            var s = new Rect(x0, y0, x1 - x0, y1 - y0);
            if (s.Height < 18) { s.Inflate(0, (18 - s.Height) / 2); s.Intersect(new Rect(0, 0, w, h)); }
            strips.Add(s);
        }
        for (int rr = 0; rr < rows; rr++)
        {
            var runs = new List<(int, int)>();
            for (int cc = 0; cc < cols; cc++)
            {
                if (!need[rr * cols + cc]) continue;
                if (runs.Count > 0 && cc - runs[^1].Item2 <= 3) runs[^1] = (runs[^1].Item1, cc); else runs.Add((cc, cc));
            }
            foreach (var (c0, c1) in runs)
            {
                int k = open.FindIndex(o => o.R1 >= rr - 2 && o.C0 <= c1 + 3 && o.C1 >= c0 - 3);
                if (k >= 0) open[k] = (Math.Min(open[k].C0, c0), Math.Max(open[k].C1, c1), open[k].R0, rr);
                else open.Add((c0, c1, rr, rr));
            }
            for (int k = open.Count - 1; k >= 0; k--) if (open[k].R1 < rr - 1) { Close(open[k]); open.RemoveAt(k); }
        }
        foreach (var o in open) Close(o);
        return strips;
    }

    /// Translates text the app reports just above and below the area (web pages, documents),
    /// up to two heights each way, so it is ready the moment it scrolls into view. Not for
    /// models running on this PC, where it would cost real work for text that may never be seen.
    void Prefetch()
    {
        if (Settings.Current.EffectiveEngine is EngineKind.Local or EngineKind.Ollama || !Settings.Current.UseAccessibility) return;
        var around = new Int32Rect(area.X, area.Y - area.Height * 2, area.Width, area.Height * 5);
        var target = Settings.Current.TargetLanguage;
        var a = area; var sc = scale;
        _ = Task.Run(async () =>
        {
            try
            {
                var texts = Uia.Items(a, sc, beyond: around, budgetMs: 1000).Select(i => i.Text)
                    .Where(t => t.Length > 3 && Translation.Cached(t, target) == null).Distinct().Take(150).ToList();
                if (texts.Count == 0) return;
                await Translation.Translate(texts, target);
                Debug.Log($"follow prefetched {texts.Count} texts");
            }
            catch (Exception e) { Debug.Log("follow prefetch " + e.Message); }
        });
    }
}

/// Works out, from frame to frame, where each translated block's text has gone. Runs on the
/// capture thread; frames are kept as one byte of brightness per point.
public sealed class MotionTracker(double scale)
{
    public sealed record Token(int Sequence, byte[] Luma, int W, int H, PixelBuffer? Pixels, int Reference, int[] Shifts, HashSet<int> Hidden);
    /// `Time`: when the frame was captured (seconds on the follower's clock).
    public sealed record Motion(int Reference, int[]? Shifts, HashSet<int> Hidden, double Time);

    readonly record struct Box(int X0, int X1, int Y0, int Y1, float Contrast);

    readonly object gate = new();
    PixelBuffer? latest;
    int w, h, changes, refId;
    byte[] luma = [], print = [], reference = [], refSmall = [];
    Box[] boxes = [];
    int[] last = [], lastBand = [];
    HashSet<int> lastHidden = [];
    const int BandCount = 4, Small = 8;

    public bool HasFrame { get { lock (gate) return luma.Length > 0; } }
    public int ReferenceId { get { lock (gate) return refId; } }

    public void Reset() { lock (gate) { luma = []; print = []; boxes = []; reference = []; latest?.Dispose(); latest = null; refId++; } }

    /// The current frame: its brightness (to follow from) and a copy of its pixels (to read).
    public Token? Begin(bool copyPixels)
    {
        lock (gate)
        {
            if (luma.Length == 0) return null;
            PixelBuffer? px = null;
            if (copyPixels && latest is { } l)
            {
                px = new PixelBuffer(l.Width, l.Height);
                l.Span.CopyTo(px.Span);
            }
            return new Token(changes, luma, w, h, px, refId, last, lastHidden);
        }
    }

    /// Makes `rects` (points within the area, as they were in frame `t`) the blocks to follow.
    /// False if that can't be done (the area changed size); `catchUp` says where the blocks are
    /// now if the screen moved since `t`.
    public bool SetReference(Token t, List<Rect> rects, out Motion? catchUp)
    {
        lock (gate)
        {
            catchUp = null;
            if (t.Luma.Length == 0 || t.W != w || t.H != h) return false;
            reference = t.Luma;
            refSmall = Shrink(reference, w, h);
            boxes = rects.Select(r =>
            {
                int x0 = Math.Max(0, (int)r.Left), x1 = Math.Min(w, (int)r.Right), y0 = Math.Max(0, (int)r.Top), y1 = Math.Min(h, (int)r.Bottom);
                return new Box(x0, Math.Max(x0, x1), y0, Math.Max(y0, y1), Contrast(reference, w, x0, Math.Max(x0, x1), y0, Math.Max(y0, y1)));
            }).ToArray();
            last = new int[rects.Count];
            lastHidden = [];
            lastBand = new int[BandCount];
            refId++;
            if (t.Sequence != changes) catchUp = Track(luma, 0);
            return true;
        }
    }

    /// Takes ownership of `px`. Null when the frame looks the same as the previous one.
    public Motion? Frame(PixelBuffer px, double time)
    {
        var fp = Live.Fingerprint(px);
        lock (gate)
        {
            if (!Live.Differs(fp, print)) { px.Dispose(); return null; }
            print = fp;
            // One brightness sample per point is plenty to follow motion.
            int fw = (int)(px.Width / scale), fh = (int)(px.Height / scale);
            var l = new byte[fw * fh];
            unsafe
            {
                byte* p = (byte*)px.Base;
                for (int y = 0; y < fh; y++)
                {
                    int sy = Math.Min(px.Height - 1, (int)(y * scale));
                    byte* row = p + sy * px.Stride;
                    for (int x = 0; x < fw; x++)
                    {
                        byte* q = row + Math.Min(px.Width - 1, (int)(x * scale)) * 4;
                        l[y * fw + x] = (byte)((q[0] + 2 * q[1] + q[2]) >> 2);
                    }
                }
            }
            if (fw != w || fh != h) { w = fw; h = fh; boxes = []; reference = []; }
            luma = l;
            latest?.Dispose();
            latest = px;
            changes++;
            if (boxes.Length == 0) return new Motion(refId, null, [], time);
            return Track(l, time);
        }
    }

    /// How far each vertical band scrolled (coarse on an 8× smaller copy within ±70% of the
    /// height, then to the point), then, per block, which of those moves (or none, or its
    /// previous one) its text matches.
    public string DebugBands = "";

    Motion Track(byte[] l, double time)
    {
        DebugBands = $"{w}x{h}";
        var cur = Shrink(l, w, h);
        int sw = w / Small, sh = h / Small;
        var candidates = new HashSet<int> { 0 };
        for (int b = 0; b < BandCount; b++)
        {
            int x0 = b * sw / BandCount, x1 = (b + 1) * sw / BandCount;
            (float s, int d) coarse = (float.PositiveInfinity, 0);
            for (int d = -(sh * 7 / 10); d <= sh * 7 / 10; d++)
            {
                // Scrolling is continuous: among similar matches (repeated text), prefer the one
                // nearest the last move.
                float s = TrimmedSad(refSmall, cur, sw, sh, x0, x1, d, 1, Math.Max(6, sh / 4)) * Near(d * Small, lastBand[b]);
                if (s < coarse.s) coarse = (s, d);
            }
            if (float.IsPositiveInfinity(coarse.s)) continue;
            (float s, int d) fine = (float.PositiveInfinity, 0);
            int fx0 = x0 * Small, fx1 = x1 * Small;
            for (int d = coarse.d * Small - Small; d <= coarse.d * Small + Small; d++)
            {
                float s = TrimmedSad(reference, l, w, h, fx0, fx1, d, 3, h / 4);
                if (s < fine.s) fine = (s, d);
            }
            if (!float.IsPositiveInfinity(fine.s)) { candidates.Add(fine.d); lastBand[b] = fine.d; }
            DebugBands += $" b{b}:{coarse.d * Small}/{coarse.s:0.0}→{fine.d}/{fine.s:0.0}";
        }
        var shifts = new int[boxes.Length];
        var hide = new HashSet<int>();
        last = (int[])last.Clone();   // tokens already handed out keep the moves they were given
        for (int i = 0; i < boxes.Length; i++)
        {
            var bx = boxes[i];
            (float s, int d) best = (float.PositiveInfinity, 0);
            foreach (var d in candidates.Append(last[i]))
            {
                float s = BlockScore(reference, l, w, h, bx, d) / Math.Max(bx.Contrast, 4) * Near(d, last[i]);
                if (s < best.s) best = (s, d);
            }
            // Mostly scrolled out of view or changed: hide it rather than guess.
            if (best.s < 0.35) { shifts[i] = best.d; last[i] = best.d; } else { hide.Add(i); shifts[i] = last[i]; }
        }
        lastHidden = hide;
        return new Motion(refId, shifts, hide, time);
    }

    /// How well a block matches at move `d`, judged in up to eight side-by-side pieces using
    /// the 60th-percentile piece: a scroll bar, the pointer or a caret over part of it doesn't count.
    static float BlockScore(byte[] a, byte[] b, int w, int h, Box box, int d)
    {
        int minRows = Math.Max(1, (box.Y1 - box.Y0) * 2 / 3), width = box.X1 - box.X0;
        int pieces = Math.Max(1, Math.Min(8, width / 24));
        var scores = new float[pieces];
        for (int k = 0; k < pieces; k++)
            scores[k] = Sad(a, b, w, h, box.X0 + k * width / pieces, box.X0 + (k + 1) * width / pieces, box.Y0, box.Y1, d, 2, minRows);
        Array.Sort(scores);
        return scores[Math.Min(scores.Length - 1, scores.Length * 6 / 10)];
    }

    static float Near(int d, int last) => 1 + Math.Abs(d - last) / 300f;

    /// Mean brightness difference between `a` in the box and `b` moved down by `d`.
    static float Sad(byte[] a, byte[] b, int w, int h, int x0, int x1, int y0, int y1, int d, int step, int minRows)
    {
        int lo = Math.Max(y0, -d), hi = Math.Min(y1, h - d);
        if (hi - lo < minRows || x1 <= x0 || a.Length < w * h || b.Length < w * h) return float.PositiveInfinity;
        long s = 0; int n = 0;
        for (int y = lo; y < hi; y++)
        {
            int oa = y * w, ob = (y + d) * w;
            for (int x = x0; x < x1; x += step) { s += Math.Abs(a[oa + x] - b[ob + x]); n++; }
        }
        return n == 0 ? float.PositiveInfinity : (float)s / n;
    }

    /// Like Sad over a whole band, but leaving out the worst-matching quarter of rows: a
    /// window's own toolbar or status bar doesn't scroll, and on Windows it is often dark
    /// against a light page, so it would otherwise outweigh the content that did move.
    [ThreadStatic] static float[]? rowBuf;
    static float TrimmedSad(byte[] a, byte[] b, int w, int h, int x0, int x1, int d, int step, int minRows)
    {
        int lo = Math.Max(0, -d), hi = Math.Min(h, h - d);
        if (hi - lo < minRows || x1 <= x0 || a.Length < w * h || b.Length < w * h) return float.PositiveInfinity;
        int n = hi - lo;
        var rows = rowBuf is { } r && r.Length >= n ? r : rowBuf = new float[Math.Max(n, 2048)];
        for (int y = lo; y < hi; y++)
        {
            int oa = y * w, ob = (y + d) * w, s = 0, k = 0;
            for (int x = x0; x < x1; x += step) { s += Math.Abs(a[oa + x] - b[ob + x]); k++; }
            rows[y - lo] = k == 0 ? 0 : (float)s / k;
        }
        Array.Sort(rows, 0, n);
        int keep = Math.Max(1, n * 3 / 4);
        float sum = 0;
        for (int i = 0; i < keep; i++) sum += rows[i];
        return sum / keep;
    }

    static float Contrast(byte[] a, int w, int x0, int x1, int y0, int y1)
    {
        if (x1 <= x0 || y1 <= y0) return 0;
        long sum = 0; int n = 0;
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) { sum += a[y * w + x]; n++; }
        int mean = (int)(sum / n);
        long dev = 0;
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) dev += Math.Abs(a[y * w + x] - mean);
        return (float)dev / n;
    }

    static byte[] Shrink(byte[] a, int w, int h)
    {
        int sw = w / Small, sh = h / Small;
        var outp = new byte[Math.Max(0, sw * sh)];
        for (int y = 0; y < sh; y++)
            for (int x = 0; x < sw; x++)
            {
                int s = 0;
                for (int yy = 0; yy < Small; yy++) { int o = (y * Small + yy) * w + x * Small; for (int xx = 0; xx < Small; xx++) s += a[o + xx]; }
                outp[y * sw + x] = (byte)(s / (Small * Small));
            }
        return outp;
    }
}

/// A small bar at the bottom of a followed translation: the language, a spinner while new
/// text is being translated, and ✕ to stop.
public sealed class FollowBar
{
    readonly Window panel;
    readonly Ellipse spinner;

    public FollowBar(Int32Rect area, Native.Monitor mon, Language target, Action stop)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(11, 5, 6, 5) };
        row.Children.Add(new TextBlock { Text = "文A", Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 7, 0) });
        row.Children.Add(new TextBlock { Text = $"Translated to {target.Name}", Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center });
        spinner = new Ellipse
        {
            Width = 12, Height = 12, Margin = new Thickness(8, 0, 0, 0), StrokeThickness = 2, Stroke = Brushes.White, StrokeDashArray = [3, 2],
            RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new RotateTransform(), Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(spinner);
        var close = new Button
        {
            Content = "✕", ToolTip = "Stop translating", Foreground = new SolidColorBrush(Color.FromArgb(200, 255, 255, 255)), Background = Brushes.Transparent,
            BorderThickness = new Thickness(0), FontSize = 12, Padding = new Thickness(6, 0, 4, 0), Margin = new Thickness(4, 0, 0, 0), Cursor = System.Windows.Input.Cursors.Hand,
        };
        close.Click += (_, _) => stop();
        row.Children.Add(close);
        var border = new Border
        {
            Child = row, CornerRadius = new CornerRadius(14), Background = new SolidColorBrush(Color.FromArgb(230, 32, 32, 34)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(60, 255, 255, 255)), BorderThickness = new Thickness(1), Margin = new Thickness(8),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 10, ShadowDepth = 2, Opacity = 0.3 },
        };
        panel = Hud.Panel(border, clickThrough: false);
        panel.Show();
        var src = PresentationSource.FromVisual(panel);
        double k = src?.CompositionTarget.TransformToDevice.M11 ?? mon.Scale;
        int cw = (int)(panel.ActualWidth * k), ch = (int)(panel.ActualHeight * k);
        int bottom = Math.Min(area.Y + area.Height, mon.Work.Y + mon.Work.Height) - ch - (int)(4 * k);
        Native.SetWindowPos(new WindowInteropHelper(panel).Handle, new IntPtr(-1), area.X + (area.Width - cw) / 2, bottom, 0, 0, 0x0001 | 0x0010 | 0x0040);
    }

    public bool Busy
    {
        set
        {
            spinner.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            var rt = (RotateTransform)spinner.RenderTransform;
            if (value) rt.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.9)) { RepeatBehavior = RepeatBehavior.Forever });
            else rt.BeginAnimation(RotateTransform.AngleProperty, null);
        }
    }

    public void Close() => panel.Close();
}
