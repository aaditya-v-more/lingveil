using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Lingveil.Core;

namespace Lingveil.App;

/// Small panels that never take focus: a toast near the top of the screen, one-time tips at
/// the bottom (shared/SPEC.md §2.15) and the Ko-fi card (§2.16).
public static class Hud
{
    /// A borderless, non-activating, topmost window around `content`, left out of capture.
    public static Window Panel(UIElement content, bool clickThrough)
    {
        var w = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true,
            ShowInTaskbar = false, ShowActivated = false, ResizeMode = ResizeMode.NoResize, SizeToContent = SizeToContent.WidthAndHeight,
            Content = content, Left = -10000, Top = -10000, FontFamily = new FontFamily("Segoe UI"),
        };
        w.SourceInitialized += (_, _) =>
        {
            var h = new WindowInteropHelper(w).Handle;
            Native.MakeOverlay(h, clickThrough);
            Native.ExcludeFromCapture(h);
        };
        return w;
    }

    /// Places a shown panel inside the work area of the monitor under the pointer:
    /// `y` = "top" / "bottom", horizontally centred, or bottom-right for "corner".
    public static void Place(Window w, string where)
    {
        var mon = Native.UnderCursor;
        var src = PresentationSource.FromVisual(w);
        double k = src?.CompositionTarget.TransformToDevice.M11 ?? mon.Scale;
        int cw = (int)(w.ActualWidth * k), ch = (int)(w.ActualHeight * k);
        var work = mon.Work;
        int x = work.X + (work.Width - cw) / 2, y = where switch
        {
            "top" => work.Y + (int)(24 * k),
            "bottom" => work.Y + work.Height - ch - (int)(40 * k),
            _ => work.Y + work.Height - ch - (int)(16 * k),
        };
        if (where == "corner") x = work.X + work.Width - cw - (int)(16 * k);
        Native.SetWindowPos(new WindowInteropHelper(w).Handle, new IntPtr(-1), x, y, 0, 0, 0x0001 | 0x0010 | 0x0040);
    }

    static Border Dark(UIElement child, double radius) => new()
    {
        Child = child, CornerRadius = new CornerRadius(radius), Background = new SolidColorBrush(Color.FromArgb(235, 32, 32, 34)),
        BorderBrush = new SolidColorBrush(Color.FromArgb(60, 255, 255, 255)), BorderThickness = new Thickness(1), Margin = new Thickness(10),
        Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 12, ShadowDepth = 2, Opacity = 0.3 },
    };

    static void FadeIn(Window w, double ms)
    {
        w.Opacity = 0;
        w.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(ms)));
    }

    static void FadeOutAndClose(Window w, double ms)
    {
        var a = new DoubleAnimation(w.Opacity, 0, TimeSpan.FromMilliseconds(ms));
        a.Completed += (_, _) => w.Close();
        w.BeginAnimation(UIElement.OpacityProperty, a);
    }

    static void After(double seconds, Action a)
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        t.Tick += (_, _) => { t.Stop(); a(); };
        t.Start();
    }

    // MARK: toast

    static Window? toast;
    public static string? LastToast { get; private set; }

    /// A short message near the top of the screen, for things that need no action.
    public static void Flash(string text)
    {
        LastToast = text;
        Debug.Log("toast " + text);
        toast?.Close();
        var label = new TextBlock { Text = text, Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.Medium, Margin = new Thickness(16, 8, 16, 8) };
        var w = Panel(Dark(label, 10), clickThrough: true);
        w.Show();
        Place(w, "top");
        toast = w;
        After(2.5, () => { if (toast == w) { w.Close(); toast = null; } });
    }

    // MARK: tips

    static Window? tip;

    /// One-time hints the first time a feature is used: overlay, reading, card, live.
    public static void Tip(string kind)
    {
        var s = Settings.Current;
        if (s.TipsShown.Contains(kind)) return;
        s.TipsShown.Add(kind); s.Save();
        string Key(string id) => Tray.ShortcutText(id) ?? "the shortcut";
        string text = kind switch
        {
            "overlay" => s.FollowScroll
                ? $"The translation stays while you scroll and click. Hold Alt to see the original; {Key("screen")} again ends it."
                : $"Tip: hold Alt to see the original. Right-click to copy. {Key("read")} reads it aloud.",
            "reading" => $"Reading aloud. Press {Key("read")} again or Esc to stop. Voices and speed are in Settings → Voices.",
            "card" => "Tip: the speaker button reads the translation aloud.",
            "live" => $"Live translation keeps this area translated as it changes. {Key("live")} or Alt+Esc stops it.",
            _ => "",
        };
        if (text.Length > 0) After(0.6, () => ShowTip(text));
    }

    static void ShowTip(string text)
    {
        tip?.Close();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(12, 9, 14, 9) };
        row.Children.Add(new TextBlock { Text = "💡", FontSize = 14, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Top });
        row.Children.Add(new TextBlock { Text = text, Foreground = Brushes.White, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, MaxWidth = 380 });
        var w = Panel(Dark(row, 10), clickThrough: true);
        w.Show();
        Place(w, "bottom");
        FadeIn(w, 200);
        tip = w;
        After(7, () => { if (tip == w) { tip = null; FadeOutAndClose(w, 300); } });
    }

    /// Lets the tips show again (Settings → General → Show Tutorial).
    public static void ResetTips() { Settings.Current.TipsShown.Clear(); Settings.Current.Save(); }

    // MARK: support

    static Window? card;
    static readonly Brush KoFiRed = new SolidColorBrush(Color.FromRgb(255, 94, 91));

    /// Counts one use (a translation shown, something read aloud).
    public static void Used()
    {
        var s = Settings.Current;
        s.Uses++;
        long today = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 86_400;
        if (s.LastUseDay != today) { s.LastUseDay = today; s.UseDays++; }
        s.FirstUse ??= DateTime.UtcNow;
        s.Save();
    }

    /// At a quiet moment after a translation closes or reading ends: only for frequent users
    /// (30+ uses on 5+ days, 14+ days after first use), then not again for 30 days.
    public static void MaybeAsk()
    {
        var s = Settings.Current;
        if (card != null || s.Uses < 30 || s.UseDays < 5) return;
        if (s.SupportQuietUntil is { } until && until > DateTime.UtcNow) return;
        if (s.FirstUse is { } first && DateTime.UtcNow - first < TimeSpan.FromDays(14)) return;
        s.SupportQuietUntil = DateTime.UtcNow.AddDays(30); s.Save();
        After(1.5, () => SupportCard("Enjoying Lingveil?", "It's free and made by one person. If it helps you read the web or your apps, a coffee on Ko-fi keeps it going.", snooze: true));
    }

    /// After an update, one line about supporting it.
    public static void NoteUpdate()
    {
        var s = Settings.Current;
        var v = typeof(Hud).Assembly.GetName().Version?.ToString(3) ?? "";
        var last = s.LastVersion;
        s.LastVersion = v; s.Save();
        if (last == null || last == v) return;
        After(2, () => SupportCard($"Lingveil was updated to {v}", "Thanks for using it. If it's useful to you, you can support it on Ko-fi.", snooze: false));
    }

    public static void DebugSupportCard() =>
        SupportCard("Enjoying Lingveil?", "It's free and made by one person. If it helps you read the web or your apps, a coffee on Ko-fi keeps it going.", snooze: true);

    static void SupportCard(string title, string text, bool snooze)
    {
        card?.Close();
        var dark = Bubble.IsDark();
        Brush fg = dark ? Brushes.White : new SolidColorBrush(Color.FromRgb(0x1b, 0x1b, 0x1b));
        Brush secondary = new SolidColorBrush(dark ? Color.FromRgb(0xb0, 0xb0, 0xb0) : Color.FromRgb(0x60, 0x60, 0x60));
        var col = new StackPanel { MaxWidth = 290 };
        col.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 13, Foreground = fg });
        col.Children.Add(new TextBlock { Text = text, FontSize = 12, Foreground = secondary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 8) });
        var buttons = new WrapPanel();
        Window? w = null;
        void Dismiss() { if (card == w && w != null) { card = null; FadeOutAndClose(w, 200); } }
        var support = new Button { Content = "Support on Ko-fi", Padding = new Thickness(10, 3, 10, 3), Background = KoFiRed, Foreground = Brushes.White, BorderThickness = new Thickness(0), Margin = new Thickness(0, 0, 8, 4) };
        support.Click += (_, _) => { SettingsWindow.OpenUrl(SettingsWindow.KoFi); Dismiss(); };
        var later = new Button { Content = snooze ? "Not Now" : "Close", Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(0, 0, 8, 4) };
        later.Click += (_, _) => Dismiss();
        buttons.Children.Add(support); buttons.Children.Add(later);
        if (snooze)
        {
            var quiet = new Button { Content = "Don't show for 2 months", Background = Brushes.Transparent, BorderThickness = new Thickness(0), Foreground = secondary, FontSize = 11, Cursor = System.Windows.Input.Cursors.Hand };
            quiet.Click += (_, _) => { Settings.Current.SupportQuietUntil = DateTime.UtcNow.AddDays(60); Settings.Current.Save(); Dismiss(); };
            buttons.Children.Add(quiet);
        }
        col.Children.Add(buttons);
        var all = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(14, 14, 16, 14) };
        all.Children.Add(new TextBlock { Text = "♥", Foreground = KoFiRed, FontSize = 20, Margin = new Thickness(0, -2, 12, 0) });
        all.Children.Add(col);
        var border = new Border
        {
            Child = all, CornerRadius = new CornerRadius(12), Margin = new Thickness(10),
            Background = new SolidColorBrush(dark ? Color.FromRgb(0x2b, 0x2b, 0x2b) : Color.FromRgb(0xfb, 0xfb, 0xfb)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)), BorderThickness = new Thickness(1),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 12, ShadowDepth = 2, Opacity = 0.25 },
        };
        w = Panel(border, clickThrough: false);
        w.Show();
        Place(w, "corner");
        FadeIn(w, 250);
        card = w;
    }
}
