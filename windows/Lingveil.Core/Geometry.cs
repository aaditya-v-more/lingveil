using System.Windows;

namespace Lingveil.Core;

/// Measurements taken from the capture around one piece of text: how much plain background
/// surrounds it (so a longer translation only grows into empty space, and padding never
/// paints over a control's border), and how thick its strokes are (to pick a font weight).
/// Free space is in points.
public record struct Surroundings(double Left, double Right, double Up, double Down, bool BoundedLeft, bool BoundedRight, double Stroke);

public static class Refine
{
    /// Moves `item.Rect` to where its letters really are (letters OCR missed at either end
    /// added, icons trimmed off) and measures the free background around it. `bg` is the
    /// background the translation will be painted on, `text` the ink color.
    public static Surroundings Measure(ref TextItem item, Snapshot snap, Rgb bg, Rgb text)
    {
        var px = snap.Pixels;
        double s = snap.Scale;
        var pr = snap.PixelRect(item.Rect);
        int rx0 = Math.Max(0, (int)Math.Floor(pr.X)), ry0 = Math.Max(0, (int)Math.Floor(pr.Y));
        int rx1 = Math.Min(px.Width, (int)Math.Ceiling(pr.Right)), ry1 = Math.Min(px.Height, (int)Math.Ceiling(pr.Bottom));
        if (rx1 - rx0 < 2 || ry1 - ry0 < 2) return default;
        double rh = ry1 - ry0;
        double lineH = rh / Math.Max(1, item.Lines);
        double inkThreshold = Math.Max(0.16, Math.Min(0.4, text.Dist(bg) * 0.45));
        // Ink = close to the text's own color, so an icon or a control next to the label
        // (a grey square, a colored dot) doesn't count as more letters.
        double textMatch = Math.Max(0.2, text.Dist(bg) * 0.55);
        bool IsInk(int x, int y) { var c = px.Pixel(x, y); return c.Dist(bg) > inkThreshold && c.Dist(text) < textMatch; }
        bool IsBackground(int x, int y) => px.Pixel(x, y).Dist(bg) < 0.07;
        int y0 = (int)(ry0 + rh * 0.12), y1 = Math.Max(y0 + 1, (int)(ry1 - rh * 0.12));
        bool ColumnHasInk(int x)
        {
            if (x < 0 || x >= px.Width) return false;
            for (int y = y0; y < y1; y++) if (IsInk(x, y)) return true;
            return false;
        }
        bool ColumnIsBackground(int x)
        {
            if (x < 0 || x >= px.Width) return false;
            for (int y = y0; y < y1; y += 2) if (!IsBackground(x, y)) return false;
            return true;
        }

        // 1. Trim the box to where text-colored ink starts and ends (an icon inside the OCR box
        //    isn't text), then extend past it while letters continue, stopping after a gap of a
        //    third of a line of plain background.
        int first = -1, last = -1;
        for (int x = rx0; x < rx1; x++) if (ColumnHasInk(x)) { if (first < 0) first = x; last = x; }
        if (first >= 0 && last > first) { rx0 = first; rx1 = last + 1; }
        int gapStop = (int)Math.Max(3, lineH * 0.33), reach = (int)(lineH * 2);
        int maxX = rx1, gap = 0;
        for (int x = rx1; x < Math.Min(px.Width, rx1 + reach); x++)
            if (ColumnHasInk(x)) { maxX = x + 1; gap = 0; } else if (++gap > gapStop) break;
        int minX = rx0; gap = 0;
        for (int x = rx0 - 1; x >= Math.Max(0, rx0 - reach); x--)
            if (ColumnHasInk(x)) { minX = x; gap = 0; } else if (++gap > gapStop) break;

        // 2. Free background on each side, skipping the anti-aliased fringe next to the letters.
        int sideCap = (int)Math.Max((maxX - minX) * 1.5, lineH * 8);
        int fringe = (int)Math.Max(2, lineH * 0.25);
        int cx = maxX, skipped = 0;
        while (skipped < fringe && !ColumnIsBackground(cx) && cx < px.Width) { cx++; skipped++; }
        int n = skipped;
        while (n < sideCap && ColumnIsBackground(cx)) { n++; cx++; }
        double right = n / s; bool boundedRight = n < sideCap;
        cx = minX - 1; skipped = 0;
        while (skipped < fringe && !ColumnIsBackground(cx) && cx >= 0) { cx--; skipped++; }
        n = skipped;
        while (n < sideCap && ColumnIsBackground(cx)) { n++; cx--; }
        double left = n / s; bool boundedLeft = n < sideCap;
        int vCap = (int)Math.Max(2, lineH * 0.5);
        bool RowIsBackground(int y)
        {
            if (y < 0 || y >= px.Height) return false;
            for (int x = minX; x < maxX; x += 2) if (!IsBackground(x, y)) return false;
            return true;
        }
        n = 0; int yy = ry1;
        while (n < vCap && RowIsBackground(yy)) { n++; yy++; }
        double down = n / s;
        n = 0; yy = ry0 - 1;
        while (n < vCap && RowIsBackground(yy)) { n++; yy--; }
        double up = n / s;

        // 3. Stroke width: median length of horizontal ink runs across the middle rows.
        var runs = new List<int>();
        for (int y = y0; y < y1; y += Math.Max(1, (y1 - y0) / 8))
        {
            int run = 0;
            for (int x = minX; x < maxX; x++)
                if (IsInk(x, y)) run++; else if (run > 0) { runs.Add(run); run = 0; }
        }
        double stroke = 0;
        if (runs.Count >= 6) { runs.Sort(); stroke = runs[runs.Count / 2] / lineH; }

        item.Rect = new Rect(minX / s, ry0 / s, (maxX - minX) / s, rh / s);
        return new Surroundings(left, right, up, down, boundedLeft, boundedRight, stroke);
    }
}
