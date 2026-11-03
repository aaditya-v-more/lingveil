using System.Diagnostics;
using System.Globalization;
using System.Windows;
using SkiaSharp;

namespace Lingveil.Core;

/// Text recognition on Linux with the Tesseract command-line program (the Windows version is
/// Ocr.cs on Windows.Media.Ocr). Words come back with boxes and are turned into lines by the
/// same rules as on Windows (Ocr.SplitWords), then merged into paragraphs (Ocr.Paragraphs).
public static partial class Ocr
{
    /// Tesseract language pack for each target language it can read.
    static readonly Dictionary<string, string> Packs = new()
    {
        ["en"] = "eng", ["es"] = "spa", ["fr"] = "fra", ["de"] = "deu", ["it"] = "ita", ["pt"] = "por", ["nl"] = "nld",
        ["ru"] = "rus", ["uk"] = "ukr", ["pl"] = "pol", ["cs"] = "ces", ["sv"] = "swe", ["da"] = "dan", ["nb"] = "nor",
        ["fi"] = "fin", ["el"] = "ell", ["tr"] = "tur", ["ro"] = "ron", ["hu"] = "hun", ["ar"] = "ara", ["iw"] = "heb",
        ["zh-CN"] = "chi_sim", ["zh-TW"] = "chi_tra", ["ja"] = "jpn", ["ko"] = "kor", ["hi"] = "hin", ["th"] = "tha",
        ["bn"] = "ben", ["ta"] = "tam", ["te"] = "tel", ["kn"] = "kan", ["ml"] = "mal", ["gu"] = "guj", ["pa"] = "pan",
        ["vi"] = "vie", ["id"] = "ind",
    };

    static HashSet<string>? installed;

    public static IReadOnlySet<string> InstalledPacks()
    {
        if (installed != null) return installed;
        var set = new HashSet<string>();
        try
        {
            var o = Run(["--list-langs"], out _);
            foreach (var l in o.Split('\n').Skip(1)) if (l.Trim() is { Length: > 0 } t) set.Add(t);
        }
        catch { }
        return installed = set;
    }

    /// The packs to read with: LINGVEIL_OCR_LANGS, else English plus the languages the user
    /// reads on screen, limited to what is installed.
    static string Langs()
    {
        if (Environment.GetEnvironmentVariable("LINGVEIL_OCR_LANGS") is { Length: > 0 } env) return env;
        var have = InstalledPacks();
        var want = new List<string> { "eng" };
        foreach (var c in Settings.Current.ReadLanguages) if (Packs.TryGetValue(c, out var p) && have.Contains(p) && !want.Contains(p)) want.Add(p);
        return string.Join('+', want);
    }

    static string Run(IEnumerable<string> args, out int exit)
    {
        var psi = new ProcessStartInfo("tesseract") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["OMP_THREAD_LIMIT"] = Math.Max(1, Environment.ProcessorCount / 2).ToString();
        using var p = Process.Start(psi) ?? throw new LingveilException("tesseract is not installed (sudo apt install tesseract-ocr)");
        _ = p.StandardError.ReadToEndAsync();
        var o = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        exit = p.ExitCode;
        return o;
    }

    /// Recognizes the snapshot and groups lines into paragraphs. Item rects are in points.
    public static async Task<List<TextItem>> Items(Snapshot snap)
    {
        var lines = await Recognize(snap.Pixels, minHeightPx: 7 * snap.Scale);
        var items = lines.Select(l => new TextItem(l.Text, new Rect(l.Rect.X / snap.Scale, l.Rect.Y / snap.Scale, l.Rect.Width / snap.Scale, l.Rect.Height / snap.Scale), 1));
        return Paragraphs(items.ToList());
    }

    /// Lines in image pixels. PaddleOCR when its models are installed (LINGVEIL_OCR=tesseract
    /// forces the fallback), otherwise Tesseract.
    public static Task<List<Line>> Recognize(PixelBuffer px, double minHeightPx)
    {
        var paddle = Environment.GetEnvironmentVariable("LINGVEIL_OCR") == "tesseract" ? null : PaddleOcr.Shared;
        if (paddle == null) return RecognizeTesseract(px, minHeightPx);
        return Task.Run(() => paddle.Recognize(px)
            .Select(f => new Line(f.Text, LineBox(f.Ink, f.Text, Em(f.Text, f.Ink.Height))))   // same ink → line box rules as Windows
            .Where(l => l.Rect.Height >= minHeightPx)
            .ToList());
    }

    static Task<List<Line>> RecognizeTesseract(PixelBuffer px, double minHeightPx) => Task.Run(() =>
    {
        // Tesseract reads small screen text poorly; reading an enlarged copy is much better.
        double up = double.TryParse(Environment.GetEnvironmentVariable("LINGVEIL_OCR_UPSCALE"), CultureInfo.InvariantCulture, out var u) ? u : 2;
        string langs = Langs();
        bool cjk = langs.Split('+').Any(l => l is "jpn" or "kor" or "chi_sim" or "chi_tra");
        var tmp = Path.Combine(Path.GetTempPath(), $"lingveil-ocr-{Environment.ProcessId}-{Environment.CurrentManagedThreadId}.png");
        try
        {
            var info = new SKImageInfo(px.Width, px.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
            using var src = new SKBitmap();
            src.InstallPixels(info, px.Base, px.Stride);
            using var big = up == 1 ? src.Copy() : src.Resize(new SKImageInfo((int)(px.Width * up), (int)(px.Height * up), SKColorType.Bgra8888, SKAlphaType.Premul), SKFilterQuality.High);
            using (var img = SKImage.FromBitmap(big))
            using (var data = img.Encode(SKEncodedImageFormat.Png, 100))
            using (var f = File.Create(tmp)) data.SaveTo(f);
            string psm = Environment.GetEnvironmentVariable("LINGVEIL_OCR_PSM") ?? "11";
            var tsv = Run([tmp, "stdout", "-l", langs, "--psm", psm, "--dpi", "144", "tsv"], out var exit);
            if (exit != 0) throw new LingveilException("Text recognition failed (tesseract exit " + exit + ")");
            return Parse(tsv, up, minHeightPx, cjk);
        }
        finally { try { File.Delete(tmp); } catch { } }
    });

    static List<Line> Parse(string tsv, double up, double minHeightPx, bool cjk)
    {
        var groups = new Dictionary<(int, int, int), List<(string Text, Rect Rect)>>();
        var order = new List<(int, int, int)>();
        foreach (var row in tsv.Split('\n').Skip(1))
        {
            var c = row.TrimEnd('\r').Split('\t');
            if (c.Length < 12 || c[0] != "5") continue;
            if (!double.TryParse(c[10], CultureInfo.InvariantCulture, out var conf) || conf < 30) continue;
            var text = c[11].Trim();
            if (text.Length == 0) continue;
            var key = (int.Parse(c[2]), int.Parse(c[3]), int.Parse(c[4]));
            double L = double.Parse(c[6]), T = double.Parse(c[7]), W = double.Parse(c[8]), H = double.Parse(c[9]);
            if (!groups.TryGetValue(key, out var list)) { groups[key] = list = []; order.Add(key); }
            list.Add((text, new Rect(L / up, T / up, W / up, H / up)));
        }
        var lines = new List<Line>();
        foreach (var k in order)
            foreach (var l in SplitWords(groups[k], cjk))
                if (l.Rect.Height >= minHeightPx && l.Text.Length > 0) lines.Add(l);
        return lines;
    }
}
