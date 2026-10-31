using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace Lingveil.Core;

/// Fits and paints translations where the originals were. Used by the overlay window and
/// by the headless renderer, so both draw identically. Units are points, origin top-left.
public static class Painter
{
    /// `Box` is the painted background, `TextRect` where the text goes.
    public sealed record Laid(Rect Box, Rect TextRect, FormattedText Text, double Size, bool Dropped);

    record Ctx(IReadOnlyList<Block> Blocks, List<Rect> Rects, HashSet<int> Dropped, List<TextAlignment> Aligns, double TypicalStroke, Rect Bounds, double Ppd);

    /// Lays out every block: drops blocks that duplicate a better one, picks alignment from
    /// the surroundings, fits each block, then gives one size to blocks that belong together
    /// (a column of list rows, a menu bar).
    public static List<Laid> LayoutAll(IReadOnlyList<Block> blocks, Rect bounds, double pixelsPerDip = 1)
    {
        var rects = blocks.Select(b => b.Item.Rect).ToList();
        // Drop a block that mostly overlaps a better one (UI Automation first, then larger).
        var dropped = new HashSet<int>();
        var kept = new List<int>();
        foreach (var i in Enumerable.Range(0, blocks.Count).OrderBy(i => blocks[i].Item.FromUia ? 0 : 1).ThenByDescending(i => rects[i].Width * rects[i].Height))
        {
            var r = rects[i];
            bool covered = kept.Any(j =>
            {
                var o = Rect.Intersect(r, rects[j]);
                return !o.IsEmpty && o.Width * o.Height > Math.Min(r.Width * r.Height, rects[j].Width * rects[j].Height) * 0.3;
            });
            if (covered) dropped.Add(i); else kept.Add(i);
        }
        var aligns = Enumerable.Range(0, blocks.Count).Select(i => Alignment(blocks, rects, i)).ToList();
        var strokes = blocks.Select(b => b.Around.Stroke).Where(s => s > 0).Order().ToList();
        double typical = strokes.Count == 0 ? 0 : strokes[strokes.Count / 2];
        var ctx = new Ctx(blocks, rects, dropped, aligns, typical, bounds, pixelsPerDip);
        var laid = Enumerable.Range(0, blocks.Count).Select(i => Layout(ctx, i, null)).ToList();
        // Same size for single-line blocks anchored on the same edge with the same original
        // size: a real localized list doesn't mix sizes. The column's median caps the larger
        // ones; one long item that had to shrink further keeps its own size.
        var groups = new Dictionary<string, List<int>>();
        for (int i = 0; i < blocks.Count; i++)
        {
            if (blocks[i].Item.Lines != 1 || dropped.Contains(i)) continue;
            var r = rects[i];
            double anchor = aligns[i] == TextAlignment.Center ? r.Left + r.Width / 2 : aligns[i] == TextAlignment.Right ? r.Right : r.Left;
            var key = $"{aligns[i]}|{Math.Round(anchor / 3)}|{Math.Round(blocks[i].Item.FontSize ?? 0)}";
            if (!groups.TryGetValue(key, out var g)) groups[key] = g = [];
            g.Add(i);
        }
        foreach (var members in groups.Values.Where(m => m.Count > 1))
        {
            var sizes = members.Select(i => laid[i].Size).Order().ToList();
            double median = sizes[sizes.Count / 2];
            foreach (var i in members) if (laid[i].Size > median + 0.25) laid[i] = Layout(ctx, i, median);
        }
        return laid;
    }

    /// Single-line OCR text: centered when plain background stops at about the same distance
    /// on both sides (a button, a tab); right-aligned when it shares its right edge, but not
    /// its left, with a block just above or below (values in a settings row), or hugs a right
    /// edge with lots of room on its left.
    static TextAlignment Alignment(IReadOnlyList<Block> blocks, List<Rect> rects, int i)
    {
        var it = blocks[i].Item; var a = blocks[i].Around; var r = rects[i];
        if (it.Lines > 1) return it.Align;
        bool bothBounded = a.BoundedLeft && a.BoundedRight;
        bool even = Math.Abs(a.Left - a.Right) < Math.Max(3, (a.Left + a.Right) * (bothBounded ? 0.3 : 0.08));
        if (even && a.Left + a.Right > 4 && a.BoundedLeft == a.BoundedRight && a.Left > 2) return TextAlignment.Center;
        double mid = r.Top + r.Height / 2;
        var near = Enumerable.Range(0, rects.Count).Where(j =>
        {
            double d = Math.Abs(rects[j].Top + rects[j].Height / 2 - mid);
            return j != i && d < r.Height * 4 && d > r.Height * 0.5;
        }).ToList();
        bool sharesRight = near.Any(j => Math.Abs(rects[j].Right - r.Right) < 2.5 && Math.Abs(rects[j].Left - r.Left) > 6);
        bool sharesLeft = near.Any(j => Math.Abs(rects[j].Left - r.Left) < 2.5);
        if (sharesRight && !sharesLeft) return TextAlignment.Right;
        if (a.BoundedRight && a.Right < it.LineHeight * 0.6 && a.Left > it.LineHeight * 3 && it.Align == TextAlignment.Left) return TextAlignment.Right;
        return it.Align;
    }

    static Laid Layout(Ctx c, int i, double? cap)
    {
        var b = c.Blocks[i]; var it = b.Item; var a = b.Around; var align = c.Aligns[i];
        var orig = c.Rects[i];
        double lh = it.LineHeight;
        // Weight relative to the screen's typical stroke: absolute stroke width varies too much
        // with size and anti-aliasing to tell regular from bold on its own.
        double ratio = c.TypicalStroke > 0 ? a.Stroke / c.TypicalStroke : 1;
        var weight = it.FontFamily != null ? FontWeights.Normal : ratio >= 1.75 ? FontWeights.Bold : ratio >= 1.45 ? FontWeights.SemiBold : FontWeights.Normal;
        var face = new Typeface(new FontFamily(it.FontFamily ?? "Segoe UI"), FontStyles.Normal, weight, FontStretches.Normal);
        double baseSize = it.FontSize ?? Math.Max(8, lh * 0.8);
        var others = Enumerable.Range(0, c.Rects.Count).Where(j => j != i && !c.Dropped.Contains(j)).Select(j => c.Rects[j]).ToList();
        var brush = new SolidColorBrush(b.Palette.Text.Color);
        brush.Freeze();
        FormattedText Make(double size, double? width) => new(b.Translation, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, c.Ppd)
        {
            MaxTextWidth = width is { } w ? Math.Max(1, w) : 0,
            TextAlignment = width != null ? align : TextAlignment.Left,
            Trimming = TextTrimming.None,
        };
        double bandTop = orig.Top + orig.Height * 0.25, bandBottom = orig.Bottom - orig.Height * 0.25;
        var inRow = others.Where(o => o.Top < bandBottom && o.Bottom > bandTop).ToList();
        // A gap shared with a neighbour in the same row is split between the two, since its
        // translation may grow into the same gap (menu bars, toolbars).
        double freeRight = Math.Min(Math.Min(a.Right, inRow.Where(o => o.Left >= orig.Right - 1).Select(o => (o.Left - orig.Right) / 2 - 1).DefaultIfEmpty(double.PositiveInfinity).Min()), c.Bounds.Right - orig.Right);
        double freeLeft = Math.Min(Math.Min(a.Left, inRow.Where(o => o.Right <= orig.Left + 1).Select(o => (orig.Left - o.Right) / 2 - 1).DefaultIfEmpty(double.PositiveInfinity).Min()), orig.Left - c.Bounds.Left);
        double size = Math.Min(baseSize, cap ?? double.PositiveInfinity);
        var textRect = orig;
        FormattedText s;
        if (it.Lines == 1)
        {
            double Width(double sz) => Math.Ceiling(Make(sz, null).WidthIncludingTrailingWhitespace) + 1;
            // Widen into measured free background first (up to 2.5×, on the side the alignment
            // allows), and only then shrink what still doesn't fit. A one-line label never wraps.
            double maxGrow = Math.Max(orig.Width * 1.5, lh * 4);
            double room = align == TextAlignment.Center ? 2 * Math.Max(0, Math.Min(freeLeft, freeRight))
                        : align == TextAlignment.Right ? Math.Max(0, freeLeft) : Math.Max(0, freeRight);
            double grow = Math.Max(0, Math.Min(Math.Min(Width(size) - orig.Width, maxGrow), room));
            textRect.Width += grow;
            if (align == TextAlignment.Center) textRect.X -= grow / 2; else if (align == TextAlignment.Right) textRect.X -= grow;
            while (Width(size) > textRect.Width && size > Math.Max(7, baseSize * 0.6)) size -= 0.5;
            s = Make(size, textRect.Width);
            s.MaxLineCount = 1;
            s.Trimming = TextTrimming.CharacterEllipsis;
            // One line of the font's own height, centered on the original line.
            double lineH = Math.Ceiling(Make(size, null).Height);
            textRect = new Rect(textRect.X, Math.Round(orig.Top + orig.Height / 2 - lineH / 2), textRect.Width, lineH);
        }
        else
        {
            double tolerance = orig.Height * 1.06;
            s = Make(size, textRect.Width);
            while (s.Height > tolerance && size > Math.Max(7, baseSize * 0.7)) { size -= 0.5; s = Make(size, textRect.Width); }
            // Grow downward only into free background, never onto the next text below.
            double below = others.Where(o => o.Top >= orig.Bottom - 1 && o.Left < orig.Right && o.Right > orig.Left)
                .Select(o => o.Top - orig.Bottom - 2).DefaultIfEmpty(c.Bounds.Bottom - orig.Bottom).Min();
            double room = Math.Max(0, Math.Min(Math.Min(below, a.Down), orig.Height * 0.5));
            while (s.Height > orig.Height + room && size > Math.Max(7, baseSize * 0.55)) { size -= 0.5; s = Make(size, textRect.Width); }
            double h = Math.Min(s.Height, orig.Height + room);
            if (s.Height > h) { s.MaxTextHeight = h; s.Trimming = TextTrimming.CharacterEllipsis; }
            // Paragraphs start at the original first line.
            textRect = new Rect(orig.X, orig.Top, orig.Width, h);
        }
        // Background: the text area plus padding that stops at any border around it.
        double padX = Math.Max(2, lh * 0.18), padY = Math.Max(1, lh * 0.1);
        var fill = Rect.Union(textRect, orig);
        double addLeft = Math.Min(padX, Math.Max(0, freeLeft - (orig.Left - fill.Left)));
        double addRight = Math.Min(padX, Math.Max(0, freeRight - (fill.Right - orig.Right)));
        fill.X -= addLeft; fill.Width += addLeft + addRight;
        double addDown = Math.Min(padY, a.Down + 1), addUp = Math.Min(padY, a.Up + 1);
        fill.Y -= addUp; fill.Height += addUp + addDown;
        var box = new Rect(Math.Floor(fill.X), Math.Floor(fill.Y), Math.Ceiling(fill.Right) - Math.Floor(fill.X), Math.Ceiling(fill.Bottom) - Math.Floor(fill.Y));
        return new Laid(box, textRect, s, size, c.Dropped.Contains(i));
    }

    public static void Draw(DrawingContext dc, Block b, Laid l, OverlayStyle style)
    {
        if (l.Dropped) return;
        var p = b.Palette;
        var r = l.Box;
        bool card = style == OverlayStyle.Card;
        double radius = card ? 5 : 2;
        if (card)
        {
            // Soft shadow: a few widening translucent layers under the card.
            for (int k = 3; k >= 1; k--)
            {
                var sr = r; sr.Inflate(k, k); sr.Offset(0, 1);
                dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb((byte)(22 / k), 0, 0, 0)), null, sr, radius + k, radius + k);
            }
        }
        Brush fill = (card ? GradientAxis.None : p.Axis) switch
        {
            GradientAxis.Vertical => new LinearGradientBrush(p.Top.Color, p.Bottom.Color, 90),
            GradientAxis.Horizontal => new LinearGradientBrush(p.Top.Color, p.Bottom.Color, 0),
            _ => new SolidColorBrush(p.Background.Color),
        };
        Pen? border = card ? new Pen(new SolidColorBrush(Color.FromArgb(46, p.Text.Color.R, p.Text.Color.G, p.Text.Color.B)), 0.5) : null;
        dc.DrawRoundedRectangle(fill, border, r, radius, radius);
        dc.PushClip(new RectangleGeometry(Rect.Union(r, l.TextRect)));
        dc.DrawText(l.Text, l.TextRect.TopLeft);
        dc.Pop();
    }

    public static void DrawAll(DrawingContext dc, IReadOnlyList<Block> blocks, Rect bounds, OverlayStyle style, double pixelsPerDip = 1)
    {
        var laid = LayoutAll(blocks, bounds, pixelsPerDip);
        for (int i = 0; i < blocks.Count; i++) Draw(dc, blocks[i], laid[i], style);
    }

    /// A dark pill near the top of an area, for "Translating…" and errors.
    public static void DrawPill(DrawingContext dc, string text, Rect bounds, double pixelsPerDip = 1)
    {
        var t = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal), 12, Brushes.White, pixelsPerDip);
        var box = new Rect(bounds.X + bounds.Width / 2 - t.Width / 2 - 12, bounds.Y + Math.Min(44, bounds.Height * 0.15), t.Width + 24, t.Height + 10);
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(184, 0, 0, 0)), null, box, box.Height / 2, box.Height / 2);
        dc.DrawText(t, new Point(box.X + 12, box.Y + 5));
    }

    /// The original text in a small dark tooltip under (or above) a block.
    public static void DrawTooltip(DrawingContext dc, string text, Rect under, Rect bounds, double pixelsPerDip = 1)
    {
        var t = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Measure.UiFont, 11, Brushes.White, pixelsPerDip) { MaxTextWidth = 380 };
        var box = new Rect(under.X, under.Bottom + 4, t.Width + 12, t.Height + 8);
        if (box.Bottom > bounds.Bottom) box.Y = under.Y - box.Height - 4;
        box.X = Math.Min(Math.Max(bounds.X + 2, box.X), bounds.Right - box.Width - 2);
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(209, 0, 0, 0)), null, box, 5, 5);
        dc.DrawText(t, new Point(box.X + 6, box.Y + 4));
    }
}
