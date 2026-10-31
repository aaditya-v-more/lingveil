using System.Windows;

namespace Lingveil.Core;

public static class Colors
{
    /// `rect` is the text's rect in image pixels. The background is the most common color in
    /// a thin ring around it; the text color is the inner pixels farthest from it.
    public static Palette Sample(PixelBuffer px, Rect rect)
    {
        double ring = Math.Round(Math.Max(1, Math.Min(3, rect.Height * 0.08)));
        double x0 = Math.Floor(rect.X - ring), y0 = Math.Floor(rect.Y - ring);
        var outer = new Rect(x0, y0, Math.Ceiling(rect.Right + ring) - x0, Math.Ceiling(rect.Bottom + ring) - y0);
        outer.Intersect(new Rect(0, 0, px.Width, px.Height));
        if (outer.IsEmpty || outer.Width < 4 || outer.Height < 4) return Palette.Fallback;
        int ox = (int)outer.X, oy = (int)outer.Y, w = (int)outer.Width, h = (int)outer.Height;
        int ix0 = (int)(rect.X - outer.X), iy0 = (int)(rect.Y - outer.Y), ix1 = (int)(rect.Right - outer.X), iy1 = (int)(rect.Bottom - outer.Y);
        var topPx = new List<Rgb>(); var botPx = new List<Rgb>(); var leftPx = new List<Rgb>(); var rightPx = new List<Rgb>();
        var inside = new List<Rgb>();
        int step = Math.Max(1, w * h / 40_000), i = 0;   // cap work on huge blocks
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                if (++i % step != 0) continue;
                var c = px.Pixel(ox + x, oy + y);
                if (x >= ix0 && x < ix1 && y >= iy0 && y < iy1) inside.Add(c);
                else if (y < iy0) topPx.Add(c);
                else if (y >= iy1) botPx.Add(c);
                else if (x < ix0) leftPx.Add(c);
                else rightPx.Add(c);
            }
        var ringPx = topPx.Concat(botPx).Concat(leftPx).Concat(rightPx).ToList();
        if (ringPx.Count == 0) return Palette.Fallback;
        var bg = Rgb.Mode(ringPx);
        Rgb top = bg, bottom = bg;
        var axis = GradientAxis.None;
        // A gradient only when two opposite sides differ and the other two sit between them;
        // otherwise a band that touches a neighbouring shape fakes one.
        if (topPx.Count > 8 && botPx.Count > 8 && leftPx.Count > 2 && rightPx.Count > 2)
        {
            Rgb t = Rgb.Mode(topPx), b = Rgb.Mode(botPx), l = Rgb.Mode(leftPx), r = Rgb.Mode(rightPx);
            if (t.Dist(b) > 0.05 && l.Dist(r) < 0.04 && Rgb.Purity(topPx) > 0.6 && Rgb.Purity(botPx) > 0.6 && l.Dist(t.Mix(b, 0.5)) < 0.06)
            { top = t; bottom = b; axis = GradientAxis.Vertical; }
            else if (l.Dist(r) > 0.05 && t.Dist(b) < 0.04 && Rgb.Purity(leftPx) > 0.6 && Rgb.Purity(rightPx) > 0.6 && t.Dist(l.Mix(r, 0.5)) < 0.05)
            { top = l; bottom = r; axis = GradientAxis.Horizontal; }
        }

        // Text: inner pixels far from the background; take the farthest quarter.
        var far = inside.Select(c => (c, d: c.Dist(bg))).Where(f => f.d > 0.18).ToList();
        Rgb text;
        if (far.Count >= 4)
        {
            far.Sort((a, b) => b.d.CompareTo(a.d));
            text = Rgb.Median(far.Take(Math.Max(4, far.Count / 4)).Select(f => f.c).ToList());
        }
        else text = bg.Luma > 0.5 ? new(0.1, 0.1, 0.1) : new(0.95, 0.95, 0.95);
        if (Math.Abs(text.Luma - bg.Luma) < 0.25 && text.Dist(bg) < 0.35)
            text = bg.Luma > 0.5 ? new(0.08, 0.08, 0.08) : new(0.97, 0.97, 0.97);
        return new Palette(top, bottom, text, bg, axis);
    }
}
