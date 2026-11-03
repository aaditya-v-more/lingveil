using System.Windows;
using System.Windows.Media;
using SkiaSharp;

namespace Lingveil.Core;

/// Skia drawing half of Painter (the WPF one is Painter.Draw.cs on Windows); the layout half
/// is the shared Painter.cs. The canvas is in points: scale it by the capture's scale first.
public static partial class Painter
{
    static SKColor Sk(Color c) => new(c.R, c.G, c.B, c.A);
    static SKRect Sk(Rect r) => new((float)r.Left, (float)r.Top, (float)r.Right, (float)r.Bottom);

    public static void Draw(SKCanvas canvas, Block b, Laid l, OverlayStyle style)
    {
        if (l.Dropped) return;
        var p = b.Palette;
        var r = Sk(l.Box);
        bool card = style == OverlayStyle.Card;
        float radius = card ? 5 : 2;
        if (card)
        {
            // Soft shadow: a few widening translucent layers under the card.
            for (int k = 3; k >= 1; k--)
            {
                var sr = r; sr.Inflate(k, k); sr.Offset(0, 1);
                using var sp = new SKPaint { Color = new SKColor(0, 0, 0, (byte)(22 / k)), IsAntialias = true };
                canvas.DrawRoundRect(sr, radius + k, radius + k, sp);
            }
        }
        using var fill = new SKPaint { IsAntialias = true };
        var axis = card ? GradientAxis.None : p.Axis;
        if (axis == GradientAxis.None) fill.Color = Sk(p.Background.Color);
        else fill.Shader = SKShader.CreateLinearGradient(
            new SKPoint(r.Left, r.Top), axis == GradientAxis.Vertical ? new SKPoint(r.Left, r.Bottom) : new SKPoint(r.Right, r.Top),
            new[] { Sk(p.Top.Color), Sk(p.Bottom.Color) }, (float[]?)null, SKShaderTileMode.Clamp);
        canvas.DrawRoundRect(r, radius, radius, fill);
        if (card)
        {
            var t = p.Text.Color;
            using var border = new SKPaint { Style = SKPaintStyle.Stroke, StrokeWidth = 0.5f, IsAntialias = true, Color = new SKColor(t.R, t.G, t.B, 46) };
            canvas.DrawRoundRect(r, radius, radius, border);
        }
        canvas.Save();
        canvas.ClipRect(Sk(Rect.Union(l.Box, l.TextRect)));
        l.Text.Render(canvas, l.TextRect.X, l.TextRect.Y);
        canvas.Restore();
    }

    public static void DrawAll(SKCanvas canvas, IReadOnlyList<Block> blocks, Rect bounds, OverlayStyle style, double pixelsPerDip = 1)
    {
        var laid = LayoutAll(blocks, bounds, pixelsPerDip);
        for (int i = 0; i < blocks.Count; i++) Draw(canvas, blocks[i], laid[i], style);
    }

    /// A dark pill near the top of an area, for "Translating…" and errors.
    public static void DrawPill(SKCanvas canvas, string text, Rect bounds)
    {
        var t = new FormattedText(text, System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal), 12, Brushes.White, 1);
        var box = new Rect(bounds.X + bounds.Width / 2 - t.Width / 2 - 12, bounds.Y + Math.Min(44, bounds.Height * 0.15), t.Width + 24, t.Height + 10);
        using var bg = new SKPaint { Color = new SKColor(0, 0, 0, 184), IsAntialias = true };
        canvas.DrawRoundRect(Sk(box), (float)box.Height / 2, (float)box.Height / 2, bg);
        t.Render(canvas, box.X + 12, box.Y + 5);
    }

    /// The original text in a small dark tooltip under (or above) a block.
    public static void DrawTooltip(SKCanvas canvas, string text, Rect under, Rect bounds)
    {
        var t = new FormattedText(text, System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Measure.UiFont, 11, Brushes.White, 1) { MaxTextWidth = 380 };
        var box = new Rect(under.X, under.Bottom + 4, t.Width + 12, t.Height + 8);
        if (box.Bottom > bounds.Bottom) box.Y = under.Y - box.Height - 4;
        box.X = Math.Min(Math.Max(bounds.X + 2, box.X), bounds.Right - box.Width - 2);
        using var bg = new SKPaint { Color = new SKColor(0, 0, 0, 209), IsAntialias = true };
        canvas.DrawRoundRect(Sk(box), 5, 5, bg);
        t.Render(canvas, box.X + 6, box.Y + 4);
    }
}
