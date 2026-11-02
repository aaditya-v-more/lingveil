using System.Windows;

namespace Lingveil.Core;

/// Orders text boxes the way a person reads a window (shared/SPEC.md §2.14): split into
/// side-by-side columns where a clear vertical gap runs the full height (a sidebar and a
/// content pane), but keep rows together when the two sides line up (a form's labels and
/// values); otherwise stacked groups top to bottom; a single row left to right.
/// Rects are top-down.
public static class ReadingOrder
{
    public static List<int> Order(IReadOnlyList<Rect> rects)
    {
        var outp = new List<int>();
        Cut([.. Enumerable.Range(0, rects.Count)], rects, outp, 0);
        return outp;
    }

    static void Cut(List<int> idx, IReadOnlyList<Rect> r, List<int> outp, int depth)
    {
        if (idx.Count <= 1 || depth >= 12) { outp.AddRange(idx); return; }
        // Vertical gap (columns)?
        var byX = idx.OrderBy(i => r[i].Left).ToList();
        double reach = r[byX[0]].Right;
        for (int k = 1; k < byX.Count; k++)
        {
            if (r[byX[k]].Left - reach > 18)
            {
                var left = byX[..k]; var right = byX[k..];
                if (!RowsLineUp(left, right, r)) { Cut(left, r, outp, depth + 1); Cut(right, r, outp, depth + 1); return; }
            }
            reach = Math.Max(reach, r[byX[k]].Right);
        }
        // Horizontal gap (blocks stacked top to bottom)?
        var byY = idx.OrderBy(i => r[i].Top).ToList();
        double floor = r[byY[0]].Bottom;
        for (int k = 1; k < byY.Count; k++)
        {
            if (r[byY[k]].Top - floor > 2) { Cut(byY[..k], r, outp, depth + 1); Cut(byY[k..], r, outp, depth + 1); return; }
            floor = Math.Max(floor, r[byY[k]].Bottom);
        }
        // One row of overlapping boxes: left to right.
        outp.AddRange(idx.OrderBy(i => r[i].Left));
    }

    /// True when most boxes on the left have a partner on the right at the same height.
    static bool RowsLineUp(List<int> l, List<int> rgt, IReadOnlyList<Rect> r)
    {
        static double Mid(Rect x) => x.Top + x.Height / 2;
        int partnered = l.Count(i => rgt.Any(j => Math.Abs(Mid(r[j]) - Mid(r[i])) < Math.Min(r[j].Height, r[i].Height) * 0.6));
        return partnered >= l.Count * 0.6 && l.Count >= 2;
    }

    /// Copy Text (§2.12c): items in reading order; a tab between blocks on one row, a blank
    /// line where the gap is more than 1.2 line heights, otherwise a newline.
    public static string Arrange(IReadOnlyList<TextItem> items)
    {
        var order = Order(items.Select(i => i.Rect).ToList());
        var sb = new System.Text.StringBuilder();
        Rect? prev = null;
        foreach (var i in order)
        {
            var it = items[i];
            if (prev is { } p)
            {
                bool sameRow = Math.Abs(p.Top + p.Height / 2 - (it.Rect.Top + it.Rect.Height / 2)) < Math.Min(p.Height, it.Rect.Height) * 0.5 && it.Rect.Left > p.Right;
                if (sameRow) sb.Append('\t');
                else sb.Append(it.Rect.Top - p.Bottom > Math.Max(it.LineHeight, 8) * 1.2 ? "\n\n" : "\n");
            }
            sb.Append(it.Text);
            prev = it.Rect;
        }
        return sb.ToString();
    }
}
