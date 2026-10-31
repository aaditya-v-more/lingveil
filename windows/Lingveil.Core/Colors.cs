using System.Windows;

namespace Lingveil.Core;

public static class Colors
{
    /// `rect` is the text's rect in image pixels. Samples a ring just outside it for the
    /// background and the pixels that differ most from that background for the text.
    public static Palette Sample(PixelBuffer px, Rect rect)
    {
        double ring = Math.Round(Math.Max(2, Math.Min(6, rect.Height * 0.15)));
        double x0 = Math.Floor(rect.X - ring), y0 = Math.Floor(rect.Y - ring);
        var outer = new Rect(x0, y0, Math.Ceiling(rect.Right + ring) - x0, Math.Ceiling(rect.Bottom + ring) - y0);
        outer.Intersect(new Rect(0, 0, px.Width, px.Height));
        if (outer.IsEmpty || outer.Width < 4 || outer.Height < 4) return Palette.Fallback;
        int ox = (int)outer.X, oy = (int)outer.Y, w = (int)outer.Width, h = (int)outer.Height;
        // Inner rect in crop coordinates.
        int ix0 = (int)(rect.X - outer.X), iy0 = (int)(rect.Y - outer.Y);
        int ix1 = ix0 + (int)rect.Width, iy1 = iy0 + (int)rect.Height;
        var topPx = new List<Rgb>(); var botPx = new List<Rgb>(); var sidePx = new List<Rgb>();
        var inner = new List<(Rgb c, int y)>();
        int step = Math.Max(1, w * h / 40_000), i = 0;   // cap work on huge blocks
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                if (++i % step != 0) continue;
                var c = px.Pixel(ox + x, oy + y);
                bool inside = x >= ix0 && x < ix1 && y >= iy0 && y < iy1;
                if (inside) inner.Add((c, y));
                else if (y < iy0) topPx.Add(c);
                else if (y >= iy1) botPx.Add(c);
                else sidePx.Add(c);
            }
        var all = topPx.Concat(botPx).Concat(sidePx).ToList();
        if (all.Count == 0) return Palette.Fallback;
        var bgAll = Rgb.Median(all);
        var top = topPx.Count > 8 ? Rgb.Median(topPx.Concat(sidePx.Take(sidePx.Count / 2)).ToList()) : bgAll;
        var bot = botPx.Count > 8 ? Rgb.Median(botPx.Concat(sidePx.Skip(sidePx.Count - sidePx.Count / 2)).ToList()) : bgAll;
        if (top.Dist(bot) < 0.05) { top = bgAll; bot = bgAll; }

        // Text: inner pixels far from the (row-interpolated) background.
        double span = Math.Max(1, iy1 - iy0);
        var far = new List<(Rgb c, double d)>();
        foreach (var (c, y) in inner)
        {
            var bg = top.Mix(bot, (y - iy0) / span);
            double d = c.Dist(bg);
            if (d > 0.18) far.Add((c, d));
        }
        Rgb text;
        if (far.Count >= 4)
        {
            far.Sort((a, b) => b.d.CompareTo(a.d));
            text = Rgb.Median(far.Take(Math.Max(4, far.Count / 4)).Select(f => f.c).ToList());
        }
        else text = bgAll.Luma > 0.5 ? new(0.1, 0.1, 0.1) : new(0.95, 0.95, 0.95);
        if (Math.Abs(text.Luma - bgAll.Luma) < 0.25)
            text = bgAll.Luma > 0.5 ? new(0.08, 0.08, 0.08) : new(0.97, 0.97, 0.97);
        return new Palette(top, bot, text);
    }
}
