using System.Diagnostics;
using System.Windows;

namespace Lingveil.Core;

/// Snapshot → text items (UI Automation + OCR) → translations → colored blocks.
public static class Pipeline
{
    public static string Timings = "";

    /// Finds text in the snapshot. The front app's UI Automation text is preferred (exact
    /// strings, frames, fonts); OCR, run at the same time, confirms that text is visible and
    /// fills in anything automation can't see (images, games, video).
    public static async Task<List<TextItem>> Items(Snapshot snap, Func<List<TextItem>>? uia = null)
    {
        var sw = Stopwatch.StartNew();
        var ocrTask = Ocr.Items(snap);
        var ax = uia == null ? [] : await Task.Run(uia);
        var axMs = sw.ElapsedMilliseconds;
        var seen = EstimateSizes(await ocrTask);
        Timings = $"uia {axMs} ms ({ax.Count}), ocr done at {sw.ElapsedMilliseconds} ms ({seen.Count})";
        if (ax.Count == 0) return seen;

        static double Overlap(Rect a, Rect b) { var i = Rect.Intersect(a, b); return i.IsEmpty ? 0 : i.Width * i.Height; }
        var axValid = new List<TextItem>();
        foreach (var a0 in ax)
        {
            var a = a0;
            // OCR text lying inside the element (≥ 50% of its area) proves it is visible.
            var inside = seen.Where(o => Overlap(o.Rect, a.Rect) >= o.Rect.Width * o.Rect.Height * 0.5).ToList();
            if (inside.Count == 0) continue;
            a.Lines = inside.Sum(o => o.Lines);
            var ocrSize = inside.Select(o => o.FontSize ?? 0).Order().ElementAt(inside.Count / 2);
            // UI Automation gives element frames (a whole button), not glyph bounds, and no font:
            // the box and size come from the OCR text inside it; the string stays exact. Unlike
            // the Mac's tight AX bounds, the element frame is never part of the box.
            if (a.FontSize is not { } fs || fs < ocrSize * 0.6 || fs > ocrSize * 1.6)
            {
                a.Rect = inside.Select(o => o.Rect).Aggregate(Rect.Union);
                a.FontSize = ocrSize;
                if (inside.Count == 1) a.Align = inside[0].Align;
            }
            if (!axValid.Any(v => v.Text == a.Text && Overlap(v.Rect, a.Rect) > a.Rect.Width * a.Rect.Height * 0.5)) axValid.Add(a);
        }
        var extra = seen.Where(o =>
        {
            double area = o.Rect.Width * o.Rect.Height;
            return !axValid.Any(a => Overlap(a.Rect, o.Rect) > area * 0.25) && !ax.Any(a => Overlap(a.Rect, o.Rect) > area * 0.5);
        });
        return [.. axValid, .. extra];
    }

    /// Translates items and samples colors for each. Items already in the target language,
    /// or with nothing to translate (numbers, symbols), are left out so the original shows.
    /// Work goes out in batches; `progress` receives everything finished so far as each batch
    /// lands, so most of the screen is painted before the slowest reply arrives.
    public static async Task<List<Block>> Blocks(IReadOnlyList<TextItem> items, Snapshot snap, Language target, Rect? focus = null,
                                                 Action<List<Block>>? progress = null, CancellationToken ct = default)
    {
        var todo = items.Where(i => i.HasLetters && !i.IsLiteral && !Detect.IsAlready(i.Text, target)).ToList();
        if (todo.Count == 0) return [];
        var sw = Stopwatch.StartNew();
        // The window being worked in first, then top to bottom, so what the eye is on lands first.
        var ordered = todo.OrderBy(i => focus is { } f && f.IntersectsWith(i.Rect) ? 0 : 1).ThenBy(i => i.Rect.Top).ToList();
        // Network engines answer a batch at once; local models work line by line, so smaller
        // batches let the first lines appear while the rest are still being translated.
        bool network = Settings.Current.IsNetworkEngine;
        int size = network ? 30 : 8;
        var batches = ordered.Chunk(size).ToList();
        var done = new List<Block>();
        Exception? firstError = null;
        var gate = new object();

        async Task RunBatch(TextItem[] batch)
        {
            try
            {
                var translated = await Translation.Translate(batch.Select(b => b.Text).ToList(), target, ct);
                var blocks = new List<Block>();
                for (int k = 0; k < batch.Length; k++)
                {
                    var clean = translated[k].Trim();
                    if (clean.Length == 0 || string.Equals(clean, batch[k].Text, StringComparison.OrdinalIgnoreCase)) continue;
                    var item = batch[k];
                    var palette = Colors.Sample(snap.Pixels, snap.PixelRect(item.Rect));
                    double before = item.Rect.Width;
                    var around = Refine.Measure(ref item, snap, palette.Background, palette.Text);
                    // OCR boxes are often narrower than the letters; a size estimated from the
                    // narrow box is too small, so scale it with the measured width.
                    if (!item.FromUia && item.Lines == 1 && item.FontSize is { } sz && before > 0 && item.Rect.Width > before * 1.03)
                        item.FontSize = Math.Min(sz * item.Rect.Width / before, item.LineHeight * 1.1);
                    blocks.Add(new Block(item, Filters.CaseMatched(clean, item.Text), palette, around));
                }
                List<Block> sofar;
                lock (gate) { done.AddRange(blocks); sofar = [.. done]; }
                progress?.Invoke(sofar);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception e) { lock (gate) firstError ??= e; }
        }

        // Online batches all go out at once; local engines are already busy with one batch
        // (they run lines in parallel inside it), so their batches go one after another.
        if (network) await Task.WhenAll(batches.Select(RunBatch));
        else foreach (var b in batches) await RunBatch(b);
        Timings += $", translate {sw.ElapsedMilliseconds} ms ({todo.Count})";
        if (done.Count == 0 && firstError != null) throw firstError;
        return done;
    }

    /// OCR boxes vary in height with the glyphs inside them, so the size is taken from how
    /// wide the original text would be in the system font, then sizes within ~10% of each
    /// other are snapped together so a list keeps one size the way the app drew it.
    public static List<TextItem> EstimateSizes(List<TextItem> items)
    {
        var outItems = items.Select(it =>
        {
            // Paragraphs: size from their single lines' height, not the line pitch, which
            // includes the app's line spacing.
            double byHeight = (it.Lines > 1 ? it.GlyphHeight ?? it.LineHeight / 1.2 : it.LineHeight) * 0.8;
            double size = byHeight;
            if (it.Lines == 1 && it.Text.Length >= 4)
            {
                // Width is steadier than height (which swings with ascenders and descenders).
                double w = Measure.Width(it.Text, 20);
                if (w > 0) size = Math.Min(Math.Max(20 * it.Rect.Width / w, byHeight * 0.6), byHeight * 1.4);
            }
            it.FontSize = Math.Max(7, size);
            return it;
        }).ToList();
        var sizes = outItems.Select(i => i.FontSize!.Value).Order().ToList();
        var clusters = new List<List<double>>();
        foreach (var s in sizes)
            if (clusters.Count > 0 && s <= clusters[^1][^1] * 1.1) clusters[^1].Add(s); else clusters.Add([s]);
        for (int i = 0; i < outItems.Count; i++)
        {
            var it = outItems[i];
            var c = clusters.First(c => c.Contains(it.FontSize!.Value));
            it.FontSize = Math.Round(c[c.Count / 2] * 2) / 2;
            outItems[i] = it;
        }
        return outItems;
    }
}
