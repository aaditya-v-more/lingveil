using System.Globalization;
using System.Text;
using System.Windows;
using HarfBuzzSharp;
using SkiaSharp;
using SkiaSharp.HarfBuzz;

namespace System.Windows.Media
{
    public sealed class FontFamily(string source) { public string Source { get; } = source; }

    public sealed class Typeface(FontFamily family, FontStyle style, FontWeight weight, FontStretch stretch)
    {
        public FontFamily Family { get; } = family;
        public FontWeight Weight { get; } = weight;
    }

    /// WPF's FormattedText on Skia + HarfBuzz: wraps at MaxTextWidth, honors MaxLineCount and
    /// MaxTextHeight, trims with an ellipsis, aligns lines, and reports the same Width/Height
    /// the shared Painter fits against. Characters the font lacks (CJK, Devanagari…) are
    /// drawn with a fallback face, shaped per run.
    public sealed class FormattedText
    {
        readonly string text;
        readonly Typeface face;
        readonly double size;
        readonly SolidColorBrush? brush;
        List<Line>? layout;

        double maxWidth, maxHeight; int maxLines; TextTrimming trimming; TextAlignment align;
        public double MaxTextWidth { get => maxWidth; set { maxWidth = value; layout = null; } }
        public double MaxTextHeight { get => maxHeight; set { maxHeight = value; layout = null; } }
        public int MaxLineCount { get => maxLines; set { maxLines = value; layout = null; } }
        public TextTrimming Trimming { get => trimming; set { trimming = value; layout = null; } }
        public TextAlignment TextAlignment { get => align; set { align = value; layout = null; } }

        public FormattedText(string text, CultureInfo culture, FlowDirection flow, Typeface typeface, double emSize, Brush foreground, double pixelsPerDip)
        {
            this.text = text; face = typeface; size = emSize; brush = foreground as SolidColorBrush;
        }

        record Line(List<(string Text, SKTypeface Face, double Width)> Runs, double Width);

        SKTypeface Primary => Fonts.Resolve(face.Family.Source, face.Weight.Weight);
        double LineHeight { get { using var p = Paint(Primary); var m = p.FontMetrics; return m.Descent - m.Ascent + m.Leading; } }
        float Ascent { get { using var p = Paint(Primary); return -p.FontMetrics.Ascent; } }

        SKPaint Paint(SKTypeface tf) => new() { Typeface = tf, TextSize = (float)size, IsAntialias = true, SubpixelText = true };

        double Measure(string s, List<(string, SKTypeface, double)>? runsOut = null)
        {
            double total = 0;
            foreach (var (t, tf) in Fonts.Runs(s, Primary))
            {
                double w = Fonts.Width(t, tf, (float)size);
                runsOut?.Add((t, tf, w));
                total += w;
            }
            return total;
        }

        Line MakeLine(string s)
        {
            var runs = new List<(string, SKTypeface, double)>();
            double w = Measure(s, runs);
            return new Line(runs, w);
        }

        List<Line> Layout()
        {
            if (layout != null) return layout;
            var lines = new List<Line>();
            bool wrap = maxWidth > 0;
            bool truncated = false;
            double lh = LineHeight;
            int limit = int.MaxValue;
            if (maxLines > 0) limit = maxLines;
            if (maxHeight > 0) limit = Math.Min(limit, Math.Max(1, (int)Math.Floor(maxHeight / lh + 1e-6)));

            foreach (var para in text.Split('\n'))
            {
                var p = para.TrimEnd('\r');
                if (!wrap) { lines.Add(MakeLine(p)); continue; }
                var cur = new StringBuilder();
                foreach (var tok in Tokens(p))
                {
                    var cand = cur.ToString() + tok;
                    if (cur.Length == 0 || Measure(cand.TrimEnd()) <= maxWidth) { cur.Append(tok); continue; }
                    lines.Add(MakeLine(cur.ToString().TrimEnd()));
                    cur.Clear().Append(tok.TrimStart());
                    // A single token wider than the box (a long word, a URL) breaks by character.
                    while (cur.Length > 1 && Measure(cur.ToString().TrimEnd()) > maxWidth)
                    {
                        int k = cur.Length - 1;
                        while (k > 1 && Measure(cur.ToString(0, k)) > maxWidth) k--;
                        lines.Add(MakeLine(cur.ToString(0, k)));
                        cur.Remove(0, k);
                    }
                }
                lines.Add(MakeLine(cur.ToString().TrimEnd()));
            }
            if (lines.Count > limit) { lines.RemoveRange(limit, lines.Count - limit); truncated = true; }
            if (truncated && trimming != TextTrimming.None && lines.Count > 0)
            {
                var last = string.Concat(lines[^1].Runs.Select(r => r.Text)).TrimEnd();
                while (last.Length > 0 && Measure(last + "…") > maxWidth) last = last[..^1].TrimEnd();
                lines[^1] = MakeLine(last + "…");
            }
            else if (!truncated && wrap && trimming != TextTrimming.None && lines.Count == 1 && lines[0].Width > maxWidth)
            {
                var last = string.Concat(lines[0].Runs.Select(r => r.Text)).TrimEnd();
                while (last.Length > 0 && Measure(last + "…") > maxWidth) last = last[..^1].TrimEnd();
                lines[0] = MakeLine(last + "…");
            }
            return layout = lines;
        }

        /// Words with their trailing spaces; every CJK character is its own break opportunity.
        static IEnumerable<string> Tokens(string s)
        {
            var sb = new StringBuilder();
            bool inSpace = false;
            foreach (var ch in s)
            {
                bool cjk = ch is >= '぀' and <= '鿿' or >= '가' and <= '힯' or >= '＀' and <= '￯';
                if (cjk) { if (sb.Length > 0) { yield return sb.ToString(); sb.Clear(); } yield return ch.ToString(); inSpace = false; continue; }
                bool sp = char.IsWhiteSpace(ch);
                if (!sp && inSpace) { yield return sb.ToString(); sb.Clear(); }
                inSpace = sp;
                sb.Append(ch);
            }
            if (sb.Length > 0) yield return sb.ToString();
        }

        public double Height => Math.Max(1, Layout().Count) * LineHeight;
        public double Width => Layout().Count == 0 ? 0 : Layout().Max(l => l.Width);
        public double WidthIncludingTrailingWhitespace => Layout().Count == 0 ? 0 : Layout().Max(l => TrailingWidth(l));

        double TrailingWidth(Line l) => l.Width;   // lines are measured without their trailing space; none are kept

        /// Draws at (x, y) = top-left of the text, in the canvas's current units.
        public void Render(SKCanvas canvas, double x, double y)
        {
            var c = brush?.Color ?? new Color(255, 0, 0, 0);
            double lh = LineHeight, asc = Ascent;
            var lines = Layout();
            for (int i = 0; i < lines.Count; i++)
            {
                double lx = x;
                if (maxWidth > 0)
                    lx += align switch { TextAlignment.Center => (maxWidth - lines[i].Width) / 2, TextAlignment.Right => maxWidth - lines[i].Width, _ => 0 };
                float baseline = (float)(y + i * lh + asc);
                foreach (var (t, tf, w) in lines[i].Runs)
                {
                    using var paint = Paint(tf);
                    paint.Color = new SKColor(c.R, c.G, c.B, c.A);
                    Fonts.Draw(canvas, t, tf, paint, (float)lx, baseline);
                    lx += w;
                }
            }
        }
    }

    /// Font lookup and shaping for the shim. "Segoe UI" (what the shared code asks for) maps
    /// to the system UI font; characters the face doesn't cover come from a fallback face.
    static class Fonts
    {
        static readonly object gate = new();
        static readonly Dictionary<string, SKTypeface> faces = [];
        static readonly Dictionary<(int, string), SKTypeface> fallback = [];
        static readonly Dictionary<SKTypeface, SKShaper> shapers = [];
        static readonly string[] UiFonts = ["Ubuntu", "Noto Sans", "Cantarell", "DejaVu Sans", "Liberation Sans"];

        public static SKTypeface Resolve(string family, int weight)
        {
            lock (gate)
            {
                var key = family + "|" + weight;
                if (faces.TryGetValue(key, out var hit)) return hit;
                var style = new SKFontStyle(weight, (int)SKFontStyleWidth.Normal, SKFontStyleSlant.Upright);
                SKTypeface? tf = null;
                var names = family == "Segoe UI" || family == "system-ui" ? UiFonts : [family, .. UiFonts];
                foreach (var n in names)
                {
                    var t = SKFontManager.Default.MatchFamily(n, style);
                    if (t != null && t.FamilyName.Equals(n, StringComparison.OrdinalIgnoreCase)) { tf = t; break; }
                }
                return faces[key] = tf ?? SKTypeface.FromFamilyName(null, style) ?? SKTypeface.Default;
            }
        }

        /// Splits text into runs that each have one face able to draw them.
        public static List<(string Text, SKTypeface Face)> Runs(string text, SKTypeface primary)
        {
            var runs = new List<(string, SKTypeface)>();
            if (text.Length == 0) { runs.Add(("", primary)); return runs; }
            var sb = new StringBuilder();
            SKTypeface? cur = null;
            for (int i = 0; i < text.Length; i += char.IsSurrogatePair(text, i) ? 2 : 1)
            {
                int cp = char.ConvertToUtf32(text, i);
                string s = char.IsSurrogatePair(text, i) ? text.Substring(i, 2) : text[i].ToString();
                // Spaces and neutral marks stay with whatever run they follow.
                var tf = char.IsWhiteSpace(s[0]) && cur != null ? cur : For(cp, primary);
                if (cur != null && tf != cur) { runs.Add((sb.ToString(), cur)); sb.Clear(); }
                cur = tf; sb.Append(s);
            }
            runs.Add((sb.ToString(), cur!));
            return runs;
        }

        static SKTypeface For(int cp, SKTypeface primary)
        {
            lock (gate)
            {
                if (primary.GetGlyphs(char.ConvertFromUtf32(cp))[0] != 0) return primary;
                var key = (cp >> 7, primary.FamilyName);   // faces cover whole blocks, so cache per 128 code points
                if (fallback.TryGetValue(key, out var hit) && hit.GetGlyphs(char.ConvertFromUtf32(cp))[0] != 0) return hit;
                var f = SKFontManager.Default.MatchCharacter(primary.FamilyName, primary.FontStyle, null, cp);
                if (f != null) fallback[key] = f;
                return f ?? primary;
            }
        }

        static SKShaper ShaperFor(SKTypeface tf)
        {
            if (!shapers.TryGetValue(tf, out var s)) shapers[tf] = s = new SKShaper(tf);
            return s;
        }

        public static double Width(string text, SKTypeface tf, float size)
        {
            if (text.Length == 0) return 0;
            lock (gate)
            {
                using var paint = new SKPaint { Typeface = tf, TextSize = size, IsAntialias = true, SubpixelText = true };
                return ShaperFor(tf).Shape(text, paint).Width;
            }
        }

        public static void Draw(SKCanvas canvas, string text, SKTypeface tf, SKPaint paint, float x, float baseline)
        {
            if (text.Length == 0) return;
            lock (gate) canvas.DrawShapedText(ShaperFor(tf), text, x, baseline, paint);
        }
    }
}
