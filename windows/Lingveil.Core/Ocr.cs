using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace Lingveil.Core;

/// Text recognition with Windows.Media.Ocr. Each engine reads one language, so every OCR
/// language installed on this PC runs and overlapping lines are resolved by script.
public static class Ocr
{
    public record struct Line(string Text, Rect Rect);

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

    static bool IsCjk(char c) => c is >= '぀' and <= '鿿' || c is >= '가' and <= '힯' || c is >= '＀' and <= '￯' || c is >= '　' and <= '〿';

    /// Joins words the way they were written (no spaces between CJK characters, which
    /// Windows OCR returns as separate words), and splits a row of separate labels (a menu
    /// bar, a toolbar) into one item per label. Windows word boxes are tight, so the gap
    /// between two words is what Vision reports as a word box wider than the word: a gap
    /// wider than 1.0×h ends a label, in lines wider than 1.2× their measured text.
    static IEnumerable<Line> Split(OcrLine line, bool cjkEngine)
    {
        var words = line.Words.Select(w => (Text: w.Text, Rect: new Rect(w.BoundingRect.X, w.BoundingRect.Y, w.BoundingRect.Width, w.BoundingRect.Height))).ToList();
        if (words.Count == 0) yield break;
        var box = words.Select(w => w.Rect).Aggregate(Rect.Union);
        double h = box.Height;
        string Join(int from, int to)
        {
            var sb = new System.Text.StringBuilder(words[from].Text);
            for (int k = from + 1; k <= to; k++)
            {
                var prev = words[k - 1].Text; var cur = words[k].Text;
                if (!(IsCjk(prev[^1]) && IsCjk(cur[0])) && !(cjkEngine && (IsCjk(prev[^1]) || IsCjk(cur[0])) && words[k].Rect.X - words[k - 1].Rect.Right < h * 0.3)) sb.Append(' ');
                sb.Append(cur);
            }
            return sb.ToString().Trim();
        }
        var full = Join(0, words.Count - 1);
        double em = Em(full, h);
        // Toolbar and list icons next to a label come back as a stray symbol ("_ Settings",
        // "• Inbox"): drop single non-alphanumeric words at either end, with their box.
        bool Icon(int k) => words[k].Text.Length == 1 && !char.IsLetterOrDigit(words[k].Text[0]);
        Line Make(int from, int to)
        {
            if (to > from && Icon(from)) from++;
            if (to > from && Icon(to)) to--;
            var r = words.Skip(from).Take(to - from + 1).Select(w => w.Rect).Aggregate(Rect.Union);
            return new Line(Join(from, to), LineBox(new Rect(r.X, box.Y, r.Width, box.Height), full, em));
        }
        bool wide = h > 4 && words.Count > 1 && box.Width > Measure.Width(full, em) * 1.2;
        if (!wide) { yield return Make(0, words.Count - 1); yield break; }
        int start = 0;
        for (int k = 0; k < words.Count; k++)
        {
            bool last = k == words.Count - 1;
            if (last || words[k + 1].Rect.X - words[k].Rect.Right > em * 1.0)
            {
                yield return Make(start, k);
                start = k + 1;
            }
        }
    }

    const string Descenders = "gjpqyQ,;()[]{}|@$ç";

    /// Windows word boxes cover only the ink: cap/ascender top to the baseline, or to the
    /// descender when the line has one. The spec's constants are tuned for Vision's line
    /// boxes, which span the font's ascent and descent (~1.25 em), so the em size is
    /// estimated from the ink height and the box is grown to that full line box.
    static double Em(string text, double inkHeight) =>
        text.Any(c => IsCjk(c)) ? inkHeight / 0.9 : text.Any(c => Descenders.Contains(c)) ? inkHeight / 0.95 : inkHeight / 0.73;

    static Rect LineBox(Rect ink, string text, double em)
    {
        bool desc = text.Any(c => IsCjk(c) || Descenders.Contains(c));
        double baseline = desc ? ink.Bottom - em * 0.22 : ink.Bottom;
        double top = baseline - em * 0.98, bottom = baseline + em * 0.27;
        return new Rect(ink.X, Math.Min(top, ink.Top), ink.Width, Math.Max(bottom, ink.Bottom) - Math.Min(top, ink.Top));
    }

    static double Area(Rect r) => r.Width * r.Height;
    static double Overlap(Rect a, Rect b) { var i = Rect.Intersect(a, b); return i.IsEmpty ? 0 : i.Width * i.Height; }

    /// Merges stacked lines that read as one paragraph so they are translated together.
    /// Short lines (menu items, buttons, list rows) stay separate.
    public static List<TextItem> Paragraphs(List<TextItem> lines)
    {
        var sorted = lines.OrderBy(l => l.Rect.Top).ToList();   // top to bottom
        var outItems = new List<TextItem>();
        var used = new bool[sorted.Count];
        for (int i = 0; i < sorted.Count; i++)
        {
            if (used[i]) continue;
            used[i] = true;
            var block = sorted[i];
            var last = sorted[i];
            var lefts = new List<double> { last.Rect.Left };
            var centers = new List<double> { last.Rect.Left + last.Rect.Width / 2 };
            var heights = new List<double> { last.Rect.Height };
            var widths = new List<double> { last.Rect.Width };
            for (int j = i + 1; j < sorted.Count; j++)
            {
                if (used[j]) continue;
                var n = sorted[j];
                double h = last.Rect.Height;
                double gap = n.Rect.Top - last.Rect.Bottom;
                if (gap > h * 1.2) { if (n.Rect.Top > last.Rect.Bottom + h * 2) break; continue; }
                bool similarHeight = Math.Abs(n.Rect.Height - h) < h * 0.3;
                bool overlapsX = n.Rect.Left < last.Rect.Right && n.Rect.Right > last.Rect.Left;
                bool alignedLeft = Math.Abs(n.Rect.Left - block.Rect.Left) < h * 1.2;
                bool alignedCenter = Math.Abs(Mid(n.Rect) - Mid(block.Rect)) < h * 1.2;
                bool lastIsLong = last.Rect.Width > Math.Max(h * 9, block.Rect.Width * 0.6);
                bool endsSentence = last.Text.Length > 0 && ".!?。！？:：".Contains(last.Text[^1]);
                if (gap < h * 0.7 && gap > -h * 0.3 && similarHeight && overlapsX && (alignedLeft || alignedCenter) && lastIsLong && !endsSentence)
                {
                    used[j] = true;
                    bool hyphen = block.Text.EndsWith('-') && !block.IsCJK;
                    var joiner = block.IsCJK || block.Text.EndsWith('-') ? "" : " ";
                    var text = hyphen ? block.Text[..^1] : block.Text;
                    block = block with { Text = text + joiner + n.Text, Rect = Rect.Union(block.Rect, n.Rect), Lines = block.Lines + 1 };
                    lefts.Add(n.Rect.Left); centers.Add(Mid(n.Rect)); heights.Add(n.Rect.Height); widths.Add(n.Rect.Width);
                    last = n;
                }
            }
            if (block.Lines > 1)
            {
                heights.Sort();
                block.GlyphHeight = heights[heights.Count / 2];
                block.LinesWidth = widths.Sum();
                double leftSpread = lefts.Max() - lefts.Min(), centerSpread = centers.Max() - centers.Min();
                if (centerSpread < leftSpread * 0.5) block.Align = TextAlignment.Center;
            }
            outItems.Add(block);
        }
        return outItems;
    }

    static double Mid(Rect r) => r.Left + r.Width / 2;
}
