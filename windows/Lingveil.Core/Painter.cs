using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace Lingveil.Core;

/// Fits and paints translations where the originals were. Used by the overlay window and
/// by the headless renderer, so both draw identically. Units are points, origin top-left.
public static class Painter
{
    public sealed record Laid(Rect Box, FormattedText Text);

    static Typeface FaceOf(TextItem it) => it.FontFamily is { } f
        ? new Typeface(new FontFamily(f), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal)
        : Measure.UiFont;

    /// Picks a font size and box so the translation fits where the original was: shrink a
    /// little, then widen single lines into free space, then shrink further, then let it run
    /// onto extra lines below rather than cut it off.
    public static Laid Layout(Block b, double pixelsPerDip = 1)
    {
        var it = b.Item;
        double lh = it.LineHeight;
        double baseSize = it.FontSize ?? Math.Max(8, lh * 0.8);
        double padX = Math.Max(2, lh * 0.18), padY = Math.Max(1, lh * 0.1);
        var rect = it.Rect;
        rect.Inflate(padX, padY);
        var face = FaceOf(it);
        var brush = new SolidColorBrush(b.Palette.Text.Color);
        brush.Freeze();
        FormattedText Make(double size, double width)
        {
            var t = new FormattedText(b.Translation, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, pixelsPerDip)
            {
                MaxTextWidth = Math.Max(1, width - 2),
                TextAlignment = it.Align,
                Trimming = TextTrimming.None,
            };
            return t;
        }
        double tolerance = rect.Height * 1.06;
        // Fallback fonts (Nirmala UI for Devanagari, Yu Gothic for Japanese) have taller lines
        // than the box OCR measured, so text also fits when it takes no more lines than the original.
        bool Fits(FormattedText t, double size)
        {
            if (t.Height <= tolerance) return true;
            double one = new FormattedText("Xg", CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, pixelsPerDip).Height;
            var single = new FormattedText(b.Translation, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, pixelsPerDip).Height;
            return Math.Round(t.Height / Math.Max(one, single)) <= it.Lines;
        }
        double size = baseSize, floor1 = baseSize * 0.76;
        while (size > floor1 && !Fits(Make(size, rect.Width), size)) size -= 0.5;
        var s = Make(size, rect.Width);
        if (!Fits(s, size) && it.Lines == 1)
        {
            // Single line that still doesn't fit: let it grow sideways (up to 60%).
            var one = new FormattedText(b.Translation, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, pixelsPerDip);
            double grow = Math.Min(one.WidthIncludingTrailingWhitespace + 4, rect.Width * 1.6) - rect.Width;
            if (grow > 0)
            {
                rect.Width += grow;
                if (it.Align == TextAlignment.Center) rect.X -= grow / 2;
                s = Make(size, rect.Width);
            }
        }
        while (!Fits(s, size) && size > Math.Max(7, baseSize * 0.7)) { size -= 0.5; s = Make(size, rect.Width); }
        double need = s.Height + 2;
        if (need > rect.Height) rect.Height = need;   // grows downward
        return new Laid(new Rect(Math.Floor(rect.X), Math.Floor(rect.Y), Math.Ceiling(rect.Width), Math.Ceiling(rect.Height)), s);
    }

    public static void Draw(DrawingContext dc, Block b, Laid l, OverlayStyle style)
    {
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
        Brush fill = p.IsGradient && !card
            ? new LinearGradientBrush(p.Top.Color, p.Bottom.Color, 90)
            : new SolidColorBrush(p.Top.Color);
        Pen? border = card ? new Pen(new SolidColorBrush(Color.FromArgb(46, p.Text.Color.R, p.Text.Color.G, p.Text.Color.B)), 0.5) : null;
        dc.DrawRoundedRectangle(fill, border, r, radius, radius);
        double h = Math.Min(l.Text.Height, r.Height);
        dc.PushClip(new RectangleGeometry(r));
        dc.DrawText(l.Text, new Point(r.X + 1, r.Y + (r.Height - h) / 2));
        dc.Pop();
    }

    public static void DrawAll(DrawingContext dc, IEnumerable<Block> blocks, OverlayStyle style, double pixelsPerDip = 1)
    {
        foreach (var b in blocks) Draw(dc, b, Layout(b, pixelsPerDip), style);
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
