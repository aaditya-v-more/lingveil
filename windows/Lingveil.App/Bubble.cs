using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Lingveil.Core;

namespace Lingveil.App;

/// A small floating card with a translation, for the text under the pointer or a selection
/// (shared/SPEC.md §2.11).
public sealed class Bubble
{
    public static readonly Bubble Shared = new();
    Window? card;
    int? escKey;
    DispatcherTimer? watch;
    public string? DebugText { get; private set; }

    /// Set by the debug listener so pointer mode can run without moving the mouse.
    public static Native.POINT? DebugPoint;

    string lastText = "";

    /// `quiet` (hover with Alt): no "No text" card, and the same text isn't shown twice.
    public async void UnderPointer(bool quiet = false)
    {
        var p = DebugPoint ?? Native.Cursor;
        DebugPoint = null;
        if (!quiet) Close();
        var found = await Task.Run(() => FromUia(p));
        if (found == null)
        {
            // Nothing from automation: read a 900×280 area around the pointer.
            var mon = Native.MonitorAt(p);
            var k = mon.Scale;
            var area = Clamp(new Int32Rect(p.X - (int)(450 * k), p.Y - (int)(140 * k), (int)(900 * k), (int)(280 * k)), mon.Bounds);
            found = await Task.Run(async () =>
            {
                using var snap = new Snapshot(Native.Capture(area), k);
                var items = await Ocr.Items(snap);
                var local = new Point((p.X - area.X) / k, (p.Y - area.Y) / k);
                var hit = items.Where(i => { var r = i.Rect; r.Inflate(4, 4); return r.Contains(local); }).Select(i => (TextItem?)i).FirstOrDefault()
                          ?? items.OrderBy(i => Dist(i.Rect, local)).Select(i => (TextItem?)i).FirstOrDefault();
                return hit is { } h ? h.Text : null;
            });
        }
        if (found == null) { if (!quiet) Show("No text under the pointer", null, p); return; }
        if (quiet && found == lastText && card != null) return;
        await TranslateAndShow(found, p);
    }

    /// `speak`: also read the translation aloud (Translate and Read Aloud with a selection).
    public async void Selection(bool speak = false)
    {
        Close();
        var p = Native.Cursor;
        var text = await Task.Run(SelectedText);
        if (string.IsNullOrWhiteSpace(text)) { Show("Select some text first", null, p); return; }
        await TranslateAndShow(text, p, speak);
    }

    async Task TranslateAndShow(string text, Native.POINT p, bool speak = false)
    {
        lastText = text;
        var target = Settings.Current.TargetLanguage;
        try
        {
            var t = (await Task.Run(() => Translation.Translate([text], target)))[0];
            Show(t, text, p);
            Hud.Used();
            if (speak) Narrator.Shared.Read([new Segment(t, null, target.Code)], _ => { });
        }
        catch (Exception e) { Show(e.Message, null, p); }
    }

    /// The automation element under the pointer: in a multi-paragraph text view only the
    /// paragraph under it, otherwise its name/value or its text children. Never our own windows.
    static string? FromUia(Native.POINT p)
    {
        try
        {
            var e = AutomationElement.FromPoint(new Point(p.X, p.Y));
            if (e == null || e.Current.ProcessId == Environment.ProcessId) return null;
            if (e.TryGetCurrentPattern(TextPattern.Pattern, out var tp))
            {
                var range = ((TextPattern)tp).RangeFromPoint(new Point(p.X, p.Y));
                range.ExpandToEnclosingUnit(TextUnit.Paragraph);
                var s = range.GetText(2000).Trim();
                if (s.Length > 0) return s;
            }
            var name = e.Current.Name?.Trim();
            if (!string.IsNullOrEmpty(name)) return name;
            if (e.TryGetCurrentPattern(ValuePattern.Pattern, out var vp) && ((ValuePattern)vp).Current.Value is { Length: > 0 } v) return v.Trim();
            var kids = e.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text));
            var parts = kids.Cast<AutomationElement>().Take(20).Select(k => k.Current.Name).Where(n => !string.IsNullOrWhiteSpace(n)).ToList();
            return parts.Count > 0 ? string.Join(" ", parts) : null;
        }
        catch { return null; }
    }

    /// Selected text from the focused element's TextPattern.
    public static string? SelectedText()
    {
        try
        {
            var f = AutomationElement.FocusedElement;
            if (f == null || f.Current.ProcessId == Environment.ProcessId) return null;
            if (f.TryGetCurrentPattern(TextPattern.Pattern, out var tp))
                return string.Concat(((TextPattern)tp).GetSelection().Select(r => r.GetText(4000))).Trim();
        }
        catch { }
        return null;
    }

    static double Dist(Rect r, Point p)
    {
        double dx = Math.Max(Math.Max(r.Left - p.X, 0), p.X - r.Right), dy = Math.Max(Math.Max(r.Top - p.Y, 0), p.Y - r.Bottom);
        return dx * dx + dy * dy;
    }

    static Int32Rect Clamp(Int32Rect r, Int32Rect b)
    {
        int x0 = Math.Max(r.X, b.X), y0 = Math.Max(r.Y, b.Y), x1 = Math.Min(r.X + r.Width, b.X + b.Width), y1 = Math.Min(r.Y + r.Height, b.Y + b.Height);
        return new Int32Rect(x0, y0, Math.Max(1, x1 - x0), Math.Max(1, y1 - y0));
    }

    public void Show(string translation, string? original, Native.POINT p)
    {
        Close();
        DebugText = (original != null ? original + " => " : "") + translation;
        var stack = new StackPanel { Margin = new Thickness(12, 10, 12, 10), MaxWidth = 380 };
        var dark = IsDark();
        Brush fg = dark ? Brushes.White : new SolidColorBrush(Color.FromRgb(0x1b, 0x1b, 0x1b));
        Brush secondary = new SolidColorBrush(dark ? Color.FromRgb(0xb0, 0xb0, 0xb0) : Color.FromRgb(0x60, 0x60, 0x60));
        stack.Children.Add(new TextBox
        {
            Text = translation, FontSize = 14, Foreground = fg, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Segoe UI"),
        });
        if (original != null && original != translation)
        {
            stack.Children.Add(new TextBlock
            {
                Text = original, FontSize = 11, Foreground = secondary, TextWrapping = TextWrapping.Wrap, MaxHeight = 4 * 15,
                TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 6, 0, 0),
            });
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
            var copy = new Button { Content = "Copy", Padding = new Thickness(8, 1, 8, 1), HorizontalAlignment = HorizontalAlignment.Left };
            copy.Click += (_, _) => { Clipboard.SetText(translation); Close(); };
            var lang = Settings.Current.TargetLanguage.Code;
            var speak = new Button { Content = "🔊", ToolTip = "Read aloud", Padding = new Thickness(8, 1, 8, 1), Margin = new Thickness(6, 0, 0, 0) };
            speak.Click += (_, _) =>
            {
                if (Narrator.Shared.IsSpeaking) Narrator.Shared.Stop();
                else Narrator.Shared.Read([new Segment(translation, null, lang)], _ => { });
            };
            row.Children.Add(copy); row.Children.Add(speak);
            stack.Children.Add(row);
        }
        var border = new Border
        {
            Child = stack, CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(dark ? Color.FromRgb(0x2b, 0x2b, 0x2b) : Color.FromRgb(0xfb, 0xfb, 0xfb)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)), BorderThickness = new Thickness(1),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 12, ShadowDepth = 2, Opacity = 0.25 },
            Margin = new Thickness(12),
        };
        var w = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true,
            ShowInTaskbar = false, ShowActivated = false, ResizeMode = ResizeMode.NoResize, SizeToContent = SizeToContent.WidthAndHeight,
            Content = border, Left = -10000, Top = -10000,
        };
        w.SourceInitialized += (_, _) =>
        {
            var h = new WindowInteropHelper(w).Handle;
            Native.MakeOverlay(h, clickThrough: false);
            Native.ExcludeFromCapture(h);
        };
        w.Show();
        // Below the pointer, or above when there's no room; inside the work area.
        var mon = Native.MonitorAt(p);
        var src = PresentationSource.FromVisual(w);
        double k = src?.CompositionTarget.TransformToDevice.M11 ?? mon.Scale;
        int cw = (int)(w.ActualWidth * k), ch = (int)(w.ActualHeight * k);
        var work = mon.Work;
        int x = Math.Clamp(p.X - (int)(12 * k), work.X, work.X + work.Width - cw);
        int y = p.Y + (int)(14 * k);
        if (y + ch > work.Y + work.Height) y = p.Y - ch - (int)(4 * k);
        Native.SetWindowPos(new WindowInteropHelper(w).Handle, new IntPtr(-1), x, y, 0, 0, 0x0001 | 0x0010 | 0x0040);
        card = w;
        escKey = HotKeys.Shared.Register(new Shortcut(0, Native.VK_ESCAPE), Close);
        if (original != null && original != translation) Hud.Tip("card");
        // Closes on a click outside it or a scroll.
        bool wasDown = true;
        watch = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(40) };
        watch.Tick += (_, _) =>
        {
            bool down = (Native.GetAsyncKeyState(0x01) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x02) & 0x8000) != 0;
            if (down && !wasDown && !w.IsMouseOver) Close();
            wasDown = down;
        };
        watch.Start();
        w.MouseWheel += (_, _) => Close();
    }

    public static bool IsDark()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    public void Close()
    {
        DebugText = null;
        watch?.Stop(); watch = null;
        HotKeys.Shared.Unregister(escKey); escKey = null;
        if (card != null) { card.Close(); card = null; Memory.Relieve(); }
    }
}
