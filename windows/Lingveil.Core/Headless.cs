using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Lingveil.Core;

/// Test hooks (shared/SPEC.md §4) that run without a screen:
///   Lingveil.exe --render in.png out.png [--scale 2]   pipeline on an image, translation painted on
///   Lingveil.exe --bench in.txt out.txt                translate lines for bench/score.py
/// LINGVEIL_TARGET, LINGVEIL_ENGINE and LINGVEIL_LOCAL_MODEL pick the target and engine.
public static class Headless
{
    public static PixelBuffer Load(string path)
    {
        var frame = BitmapDecoder.Create(new Uri(Path.GetFullPath(path)), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0];
        var bgra = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
        var px = new PixelBuffer(bgra.PixelWidth, bgra.PixelHeight);
        bgra.CopyPixels(Int32Rect.Empty, px.Base, px.Count, px.Stride);
        return px;
    }

    public static async Task<int> Render(string input, string output, double scale)
    {
        using var snap = new Snapshot(Load(input), scale);
        var sw = Stopwatch.StartNew();
        var items = await Pipeline.Items(snap);
        long ocrMs = sw.ElapsedMilliseconds;
        var target = Settings.Current.TargetLanguage;
        var blocks = await Pipeline.Blocks(items, snap, target);
        Console.WriteLine($"items {items.Count}  blocks {blocks.Count}  ocr {ocrMs} ms  translate+colors {sw.ElapsedMilliseconds - ocrMs} ms  ({Pipeline.Timings})");
        foreach (var b in blocks)
            Console.WriteLine($"• {b.Item.Lines} {(int)b.Item.Rect.X} {(int)b.Item.Rect.Y} {(int)b.Item.Rect.Width} {(int)b.Item.Rect.Height} {b.Item.FontSize:0.#}pt {Cut(b.Item.Text)} → {Cut(b.Translation)}");
        foreach (var it in items.Where(i => !blocks.Any(b => b.Item == i)))
            Console.WriteLine($"  (kept) {(int)it.Rect.X} {(int)it.Rect.Y} {(int)it.Rect.Width} {(int)it.Rect.Height} {Cut(it.Text)}");
        Write(snap, blocks, output);
        return 0;
    }

    static string Cut(string s) => (s.Length > 40 ? s[..40] : s).Replace('\n', ' ');

    public static void Write(Snapshot snap, IEnumerable<Block> blocks, string path)
    {
        var src = BitmapSource.Create(snap.Pixels.Width, snap.Pixels.Height, 96 * snap.Scale, 96 * snap.Scale, PixelFormats.Bgra32, null,
                                      snap.Pixels.Base, snap.Pixels.Count, snap.Pixels.Stride);
        var v = new DrawingVisual();
        using (var dc = v.RenderOpen())
        {
            dc.DrawImage(src, new Rect(snap.Size));
            Painter.DrawAll(dc, blocks.ToList(), new Rect(snap.Size), Settings.Current.Style, snap.Scale);
        }
        var rtb = new RenderTargetBitmap(snap.Pixels.Width, snap.Pixels.Height, 96 * snap.Scale, 96 * snap.Scale, PixelFormats.Pbgra32);
        rtb.Render(v);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(rtb));
        using var f = File.Create(path);
        enc.Save(f);
    }

    /// Translates every line twice (the second pass is the warm time) and writes the second.
    public static async Task<int> Bench(string input, string output)
    {
        var texts = File.ReadAllLines(input).Where(l => l.Length > 0).ToList();
        var target = Settings.Current.TargetLanguage;
        for (int round = 0; round < 2; round++)
        {
            var sw = Stopwatch.StartNew();
            try
            {
                // A trailing space on the second round misses the cache but not the model's.
                var outp = await Translation.Translate(texts.Select(t => t + new string(' ', round)).ToList(), target);
                if (round == 1) File.WriteAllLines(output, outp.Select(o => o.Replace("\n", " ")));
            }
            catch (Exception e) { Console.WriteLine("error: " + e.Message); }
            Console.WriteLine($"round {round}: {texts.Count} texts in {sw.ElapsedMilliseconds} ms");
        }
        return 0;
    }
}
