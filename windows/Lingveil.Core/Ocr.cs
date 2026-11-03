using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace Lingveil.Core;

/// Text recognition with Windows.Media.Ocr. Each engine reads one language, so every OCR
/// language installed on this PC runs and overlapping lines are resolved by script.
public static partial class Ocr
{
    static List<OcrEngine>? engines;

    /// Windows OCR pack tag for each target language Windows can recognize; others have none.
    public static readonly IReadOnlyDictionary<string, string> PackTags = new Dictionary<string, string>
    {
        ["en"] = "en-US", ["es"] = "es-ES", ["fr"] = "fr-FR", ["de"] = "de-DE", ["it"] = "it-IT", ["pt"] = "pt-BR",
        ["nl"] = "nl-NL", ["ru"] = "ru-RU", ["uk"] = "uk-UA", ["pl"] = "pl-PL", ["cs"] = "cs-CZ", ["sv"] = "sv-SE",
        ["da"] = "da-DK", ["nb"] = "nb-NO", ["fi"] = "fi-FI", ["el"] = "el-GR", ["tr"] = "tr-TR", ["ro"] = "ro-RO",
        ["hu"] = "hu-HU", ["ar"] = "ar-SA", ["zh-CN"] = "zh-CN", ["zh-TW"] = "zh-TW", ["ja"] = "ja-JP", ["ko"] = "ko-KR",
    };

    /// Whether an OCR pack for `code` is installed (any region of the language counts).
    public static bool HasPack(string code)
    {
        if (!PackTags.TryGetValue(code, out var tag)) return false;
        var lang = tag.Split('-')[0];
        return OcrEngine.AvailableRecognizerLanguages.Any(l => code.StartsWith("zh") ? l.LanguageTag.Equals(tag, StringComparison.OrdinalIgnoreCase) : l.LanguageTag.Split('-')[0] == lang);
    }

    /// Forgets the loaded engines so a newly installed pack is picked up.
    public static void Reset() => engines = null;

    /// When nothing was read, a hint naming a language the user reads whose OCR pack is missing.
    public static string? MissingHint() =>
        Settings.Current.ReadLanguages.Where(c => PackTags.ContainsKey(c) && !HasPack(c)).Select(c => Shared.Language(c).Name).FirstOrDefault() is { } name
            ? $"Install {name} text recognition in Settings to read this screen" : null;

    public static IReadOnlyList<string> Languages => OcrEngine.AvailableRecognizerLanguages.Select(l => l.LanguageTag).ToList();

    static List<OcrEngine> Engines()
    {
        if (engines != null) return engines;
        var list = new List<OcrEngine>();
        var profile = OcrEngine.TryCreateFromUserProfileLanguages();
        if (profile != null) list.Add(profile);
        foreach (var l in OcrEngine.AvailableRecognizerLanguages)
            if (!list.Any(e => e.RecognizerLanguage.LanguageTag == l.LanguageTag) && OcrEngine.TryCreateFromLanguage(l) is { } e) list.Add(e);
        return engines = list;
    }

    /// Recognizes the snapshot and groups lines into paragraphs. Item rects are in points.
    public static async Task<List<TextItem>> Items(Snapshot snap)
    {
        var lines = await Recognize(snap.Pixels, minHeightPx: 7 * snap.Scale);
        var items = lines.Select(l => new TextItem(l.Text, new Rect(l.Rect.X / snap.Scale, l.Rect.Y / snap.Scale, l.Rect.Width / snap.Scale, l.Rect.Height / snap.Scale), 1));
        return Paragraphs(items.ToList());
    }

    /// Lines in image pixels, label rows already split.
    public static async Task<List<Line>> Recognize(PixelBuffer px, double minHeightPx)
    {
        var all = Engines();
        if (all.Count == 0) throw new LingveilException("No Windows OCR language is installed (Settings → Time & language → Language)");
        using var bmp = ToBitmap(px);
        var results = await Task.WhenAll(all.Select(async e =>
        {
            var r = await e.RecognizeAsync(bmp);
            return r.Lines.SelectMany(l => Split(l, Cjk(e))).Where(l => l.Rect.Height >= minHeightPx && l.Text.Length > 0).ToList();
        }));
        if (results.Length == 1) return results[0];
        // Several languages: keep, for each spot, the reading whose script fits its engine best.
        var outLines = new List<Line>();
        foreach (var cand in results.SelectMany(r => r).OrderByDescending(Score))
        {
            if (outLines.Any(o => Overlap(o.Rect, cand.Rect) > Math.Min(Area(o.Rect), Area(cand.Rect)) * 0.3)) continue;
            outLines.Add(cand);
        }
        return outLines;
    }

    /// Prefers lines whose text is mostly letters of one script: an English engine reading
    /// Japanese produces short garbage, a Japanese engine reading English produces spaced
    /// single letters, so both score below the right reading.
    static double Score(Line l)
    {
        int letters = l.Text.Count(char.IsLetter);
        int cjk = l.Text.Count(c => c is >= '぀' and <= '鿿' || c is >= '가' and <= '힯');
        int latin = l.Text.Count(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z');
        int junk = l.Text.Count(c => !char.IsLetterOrDigit(c) && !char.IsWhiteSpace(c) && !".,:;!?'\"()-%&/".Contains(c));
        return Math.Max(cjk, latin) * 2 + letters - junk * 3;
    }

    static bool Cjk(OcrEngine e) => e.RecognizerLanguage.LanguageTag is var t && (t.StartsWith("ja") || t.StartsWith("zh") || t.StartsWith("ko"));

    static SoftwareBitmap ToBitmap(PixelBuffer px)
    {
        var bmp = new SoftwareBitmap(BitmapPixelFormat.Bgra8, px.Width, px.Height, BitmapAlphaMode.Premultiplied);
        var bytes = px.Span.ToArray();
        bmp.CopyFromBuffer(bytes.AsBuffer());
        return bmp;
    }

    static IEnumerable<Line> Split(OcrLine line, bool cjkEngine) =>
        SplitWords(line.Words.Select(w => (w.Text, new Rect(w.BoundingRect.X, w.BoundingRect.Y, w.BoundingRect.Width, w.BoundingRect.Height))).ToList(), cjkEngine);

}
