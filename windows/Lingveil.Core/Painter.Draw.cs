using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace Lingveil.Core;

/// WPF drawing half of Painter; the layout half (Painter.cs) is shared with the Linux app.
public static partial class Painter
{
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
