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

    /// Inline roles inside web text: a link or a text run inside a paragraph belongs to the
    /// paragraph, so it's translated together with the rest of the sentence (§2.13).
    static readonly HashSet<ControlType> InlineRoles = [ControlType.Hyperlink, ControlType.Text];

    /// UI frameworks whose Document is a web page (browsers, WebView2 and Electron apps).
    static readonly HashSet<string> WebFrameworks = ["Chrome", "Gecko", "WebView", "EdgeHTML"];

    static readonly CacheRequest Cache = MakeCache();

    static CacheRequest MakeCache()
    {
        var c = new CacheRequest { TreeScope = TreeScope.Element | TreeScope.Children, AutomationElementMode = AutomationElementMode.Full };
        c.Add(AutomationElement.ControlTypeProperty);
        c.Add(AutomationElement.NameProperty);
        c.Add(AutomationElement.BoundingRectangleProperty);
        c.Add(AutomationElement.IsOffscreenProperty);
        c.Add(AutomationElement.ProcessIdProperty);
        c.Add(AutomationElement.FrameworkIdProperty);
        c.Add(ValuePattern.IsReadOnlyProperty);
        c.Add(ValuePattern.ValueProperty);
        c.Add(AutomationElement.IsValuePatternAvailableProperty);
        return c;
    }

    sealed class Walk(Int32Rect area, double scale, int budgetMs, bool web)
    {
        public readonly List<TextItem> Items = [];
        public readonly Stopwatch Clock = Stopwatch.StartNew();
        public int Visited, NextBlock = 1;
        public Int32Rect Area => area;
        public double Scale => scale;
        public int Budget => budgetMs;
        public bool Web => web;
    }

    /// Text items of the foreground window inside `area` (physical pixels), in points of
    /// the snapshot. 350 ms budget (600 with web pages by paragraph), depth 60, 6000 nodes.
    /// `beyond`: also read text outside the window up to that rect (web pages and documents
    /// keep scrolled-away text in their tree), to translate it ahead of time.
    public static List<TextItem> Items(Int32Rect area, double scale, Int32Rect? beyond = null, int? budgetMs = null)
    {
        bool web = Settings.Current.WebParagraphs;
        var w = new Walk(area, scale, budgetMs ?? (web ? 600 : 350), web);
        try
        {
            var fg = Native.GetForegroundWindow();
            if (fg == IntPtr.Zero || Native.IsOurs(fg)) return w.Items;
            AutomationElement root;
            using (Cache.Activate()) root = AutomationElement.FromHandle(fg);
            var c = beyond ?? area;
            Visit(root, new Rect(c.X, c.Y, c.Width, c.Height), 0, null, w, beyond != null);
        }
        catch (Exception e) { Debug.Log("uia " + e.Message); }
        return web ? WebText.JoinInlineRuns(w.Items) : w.Items;
    }

    static void Visit(AutomationElement e, Rect clip, int depth, int? block, Walk w, bool beyond)
    {
        if (++w.Visited > 6000 || depth > 60 || w.Clock.ElapsedMilliseconds > w.Budget) return;
        Rect f;
        try { f = e.Cached.BoundingRectangle; } catch { return; }
        if (!f.IsEmpty && f.Width > 0 && !f.IntersectsWith(clip)) return;   // whole subtree is off screen
        var type = e.Cached.ControlType;
        if (type == ControlType.ScrollBar) return;
        // Scrolled-away text of a web page or document is wanted when reading beyond the window.
        if (!beyond && (type == ControlType.Pane || type == ControlType.List || type == ControlType.Document || type == ControlType.DataGrid || type == ControlType.Tree) && !f.IsEmpty)
            clip = Rect.Intersect(clip, f);

        bool webArea = false;
        if (type == ControlType.Document && w.Web && block == null)
        {
            try { webArea = WebFrameworks.Contains(e.Cached.FrameworkId ?? ""); } catch { }
        }

        string? text = null;
        if (type == ControlType.Text) text = e.Cached.Name;
        else if ((type == ControlType.Edit || type == ControlType.Document) && !webArea)
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
                var a = w.Area; double scale = w.Scale;
                var r = new Rect((f.X - a.X) / scale, (f.Y - a.Y) / scale, f.Width / scale, f.Height / scale);
                // Element frames are padded; without the font, estimate lines from a typical 1.33× line.
                int lines = Math.Max(1, (int)Math.Round(r.Height / 20.0));
                w.Items.Add(new TextItem(text, r, text.Contains('\n') ? Math.Max(lines, text.Split('\n').Length) : 1) { FromUia = true, Block = block });
            }
            if (type == ControlType.Text || TitledRoles.Contains(type)) return;
        }

        // Inside a web area, remember the nearest paragraph-level element for joining runs.
        int? childBlock = webArea ? w.NextBlock++ : block == null ? null : InlineRoles.Contains(type) ? block : w.NextBlock++;
        AutomationElementCollection kids;
        try
        {
            using (Cache.Activate()) kids = e.FindAll(TreeScope.Children, System.Windows.Automation.Condition.TrueCondition);
        }
        catch { return; }
        foreach (AutomationElement k in kids) Visit(k, clip, depth + 1, childBlock, w, beyond);
    }
}
