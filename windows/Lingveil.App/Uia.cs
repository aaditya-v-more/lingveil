using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using Lingveil.Core;

namespace Lingveil.App;

/// Reads text straight out of the foreground window's UI Automation tree: exact strings and
/// frames, so the translation can sit where the label was (shared/SPEC.md §2.2).
public static class Uia
{
    static readonly HashSet<ControlType> TitledRoles =
    [
        ControlType.Button, ControlType.SplitButton, ControlType.ComboBox, ControlType.CheckBox, ControlType.RadioButton,
        ControlType.MenuItem, ControlType.TabItem, ControlType.Hyperlink, ControlType.ListItem, ControlType.TreeItem, ControlType.HeaderItem,
    ];

    static readonly CacheRequest Cache = MakeCache();

    static CacheRequest MakeCache()
    {
        var c = new CacheRequest { TreeScope = TreeScope.Element | TreeScope.Children, AutomationElementMode = AutomationElementMode.Full };
        c.Add(AutomationElement.ControlTypeProperty);
        c.Add(AutomationElement.NameProperty);
        c.Add(AutomationElement.BoundingRectangleProperty);
        c.Add(AutomationElement.IsOffscreenProperty);
        c.Add(AutomationElement.ProcessIdProperty);
        c.Add(ValuePattern.IsReadOnlyProperty);
        c.Add(ValuePattern.ValueProperty);
        c.Add(AutomationElement.IsValuePatternAvailableProperty);
        return c;
    }

    /// Text items of the foreground window inside `area` (physical pixels), in points of
    /// the snapshot. 350 ms budget, depth 60, 6000 nodes.
    public static List<TextItem> Items(Int32Rect area, double scale)
    {
        var outp = new List<TextItem>();
        try
        {
            var fg = Native.GetForegroundWindow();
            if (fg == IntPtr.Zero || Native.IsOurs(fg)) return outp;
            var deadline = Stopwatch.StartNew();
            int visited = 0;
            AutomationElement root;
            using (Cache.Activate()) root = AutomationElement.FromHandle(fg);
            var clip = new Rect(area.X, area.Y, area.Width, area.Height);
            Walk(root, clip, 0, deadline, ref visited, outp, area, scale);
        }
        catch (Exception e) { Debug.Log("uia " + e.Message); }
        return outp;
    }

    static void Walk(AutomationElement e, Rect clip, int depth, Stopwatch deadline, ref int visited, List<TextItem> outp, Int32Rect area, double scale)
    {
        if (++visited > 6000 || depth > 60 || deadline.ElapsedMilliseconds > 350) return;
        Rect f;
        try { f = e.Cached.BoundingRectangle; } catch { return; }
        if (!f.IsEmpty && f.Width > 0 && !f.IntersectsWith(clip)) return;   // whole subtree is off screen
        var type = e.Cached.ControlType;
        if (type == ControlType.ScrollBar) return;
        if ((type == ControlType.Pane || type == ControlType.List || type == ControlType.Document || type == ControlType.DataGrid || type == ControlType.Tree) && !f.IsEmpty)
            clip = Rect.Intersect(clip, f);

        string? text = null;
        if (type == ControlType.Text) text = e.Cached.Name;
        else if (type == ControlType.Edit || type == ControlType.Document)
        {
            // Editable fields hold the user's own typing; leave them alone.
            try
            {
                if ((bool)e.GetCachedPropertyValue(AutomationElement.IsValuePatternAvailableProperty) &&
                    (bool)e.GetCachedPropertyValue(ValuePattern.IsReadOnlyProperty))
                    text = e.GetCachedPropertyValue(ValuePattern.ValueProperty) as string;
            }
            catch { }
        }
        else if (TitledRoles.Contains(type)) text = e.Cached.Name;

        text = text?.Trim();
        if (!string.IsNullOrEmpty(text) && text.Length < 4000 && !f.IsEmpty)
        {
            var visible = Rect.Intersect(f, clip);
            if (!visible.IsEmpty && visible.Height >= f.Height * 0.6 && visible.Width >= f.Width * 0.5)
            {
                var r = new Rect((f.X - area.X) / scale, (f.Y - area.Y) / scale, f.Width / scale, f.Height / scale);
                // Element frames are padded; without the font, estimate lines from a typical 1.33× line.
                int lines = Math.Max(1, (int)Math.Round(r.Height / 20.0));
                outp.Add(new TextItem(text, r, text.Contains('\n') ? Math.Max(lines, text.Split('\n').Length) : 1) { FromUia = true });
            }
            if (type == ControlType.Text || TitledRoles.Contains(type)) return;
        }

        AutomationElementCollection kids;
        try
        {
            using (Cache.Activate()) kids = e.FindAll(TreeScope.Children, System.Windows.Automation.Condition.TrueCondition);
        }
        catch { return; }
        foreach (AutomationElement k in kids) Walk(k, clip, depth + 1, deadline, ref visited, outp, area, scale);
    }
}
