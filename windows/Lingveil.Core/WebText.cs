namespace Lingveil.Core;

/// Web pages by paragraph (shared/SPEC.md §2.13).
public static class WebText
{
    /// Text inside a web area arrives as separate runs wherever a link or style changes.
    /// Consecutive runs from the same paragraph-level element are joined into one item, so a
    /// sentence isn't translated in pieces; stacked labels and right-hand badges stay apart.
    public static List<TextItem> JoinInlineRuns(IEnumerable<TextItem> items)
    {
        var outp = new List<TextItem>();
        foreach (var it in items)
        {
            if (outp.Count > 0 && it.Block is { } b && outp[^1].Block == b)
            {
                var last = outp[^1];
                // Runs of one sentence share a line (a link inside the text overlaps the line the
                // text before it ends on) and follow on closely, unlike a badge at the far end.
                double overlap = Math.Min(last.Rect.Bottom, it.Rect.Bottom) - Math.Max(last.Rect.Top, it.Rect.Top);
                bool sharesLine = overlap > Math.Min(last.LineHeight, it.LineHeight) * 0.3 && it.Rect.Left - last.Rect.Right < it.LineHeight * 1.5;
                if (sharesLine && last.Text.Length + it.Text.Length < 2000)
                {
                    var glue = last.Text.EndsWith(' ') || it.Text.StartsWith(' ') || (it.Text.Length > 0 && ",.;:!?)".Contains(it.Text[0])) ? "" : " ";
                    double h = Math.Min(last.LineHeight, it.LineHeight);
                    var rect = System.Windows.Rect.Union(last.Rect, it.Rect);
                    outp[^1] = last with { Text = (last.Text + glue + it.Text).Trim(), Rect = rect, Lines = Math.Max(1, (int)Math.Round(rect.Height / Math.Max(1, h))) };
                    continue;
                }
            }
            outp.Add(it);
        }
        return outp;
    }
}
