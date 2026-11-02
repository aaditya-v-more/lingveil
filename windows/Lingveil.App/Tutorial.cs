using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Lingveil.Core;

namespace Lingveil.App;

/// The tour (shared/SPEC.md §2.15): shown on first launch, and again from the tray menu or
/// Settings → General.
public sealed class Tutorial : Window
{
    static Tutorial? open;

    public static new void Show()
    {
        open ??= new Tutorial();
        ((Window)open).Show();
        open.Activate();
    }

    record Page(string Icon, string Title, string Text, string[] Keys);

    static readonly Page[] Pages =
    [
        new("文A", "Welcome to Lingveil", "Translate anything on your screen, read anything aloud, or both. Everything works from the tray icon and a few shortcuts.", []),
        new("🪟", "Translate what you see", "Press the shortcut and the app is repainted in your language, in place, and stays that way while you scroll and use it. Hold Alt to peek at the original; press the shortcut again to stop.", ["screen", "area"]),
        new("🔊", "Read anything aloud", "Reads the selected text, or the front window from top to bottom, outlining each part as it goes. Press again or Esc to stop.", ["read"]),
        new("🗣", "Translate and listen", "Translates the front window (or the selection) and reads the translation aloud.", ["translateRead"]),
        new("👆", "Just one bit", "Point at a paragraph or select text to get a small card with the translation, a copy button and a speaker.", ["cursor", "selection"]),
        new("📋", "Copy text from anything", "Drag over any part of the screen (a picture, a video, a dialog that won't let you select) and its text is on the clipboard, ready to paste.", ["copy"]),
        new("▶", "Keep it translated", "Live mode keeps an area translated while it changes: subtitles, chats, games.", ["live"]),
        new("💻", "Offline and private", "In Settings → Models and Voices you can download translation models and voices that run entirely on this PC.", []),
    ];

    int page;
    readonly StackPanel body = new() { Margin = new Thickness(40, 36, 40, 0) };
    readonly StackPanel dots = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly Button back = new() { Content = "Back", Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(0, 0, 8, 0) };
    readonly Button next = new() { Padding = new Thickness(14, 4, 14, 4), IsDefault = true };
    readonly Button skip = new() { Content = "Skip", Background = Brushes.Transparent, BorderThickness = new Thickness(0), Foreground = SystemColors.HotTrackBrush, Cursor = System.Windows.Input.Cursors.Hand };

    Tutorial()
    {
        Title = "Welcome to Lingveil";
        Width = 580; Height = 470; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Segoe UI"); FontSize = 13;
        Closed += (_, _) => open = null;
        var footer = new DockPanel { Margin = new Thickness(20) };
        DockPanel.SetDock(skip, Dock.Left);
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(back); right.Children.Add(next);
        DockPanel.SetDock(right, Dock.Right);
        footer.Children.Add(skip); footer.Children.Add(right);
        dots.HorizontalAlignment = HorizontalAlignment.Center;
        footer.Children.Add(dots);
        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(body);
        Content = root;
        skip.Click += (_, _) => Close();
        back.Click += (_, _) => { page--; Render(); };
        next.Click += (_, _) => { if (page == Pages.Length - 1) Close(); else { page++; Render(); } };
        Render();
    }

    void Render()
    {
        var p = Pages[page];
        body.Children.Clear();
        body.Children.Add(new TextBlock { Text = p.Icon, FontSize = 44, Foreground = SystemColors.HighlightBrush, HorizontalAlignment = HorizontalAlignment.Center, FontFamily = new FontFamily("Segoe UI Emoji, Yu Gothic UI, Segoe UI") });
        body.Children.Add(new TextBlock { Text = p.Title, FontSize = 22, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 8) });
        body.Children.Add(new TextBlock { Text = p.Text, Foreground = Brushes.DimGray, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 440 });
        foreach (var id in p.Keys)
        {
            var row = new DockPanel { Width = 340, Margin = new Thickness(0, 10, 0, 0) };
            var keys = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var k in (Tray.ShortcutText(id) ?? "—").Split('+'))
                keys.Children.Add(new Border
                {
                    Child = new TextBlock { Text = k, FontSize = 12, FontWeight = FontWeights.Medium },
                    Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(3, 0, 0, 0), CornerRadius = new CornerRadius(5),
                    Background = new SolidColorBrush(Color.FromArgb(18, 0, 0, 0)), BorderBrush = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)), BorderThickness = new Thickness(0.5),
                });
            DockPanel.SetDock(keys, Dock.Right);
            row.Children.Add(keys);
            row.Children.Add(new TextBlock { Text = Tray.Actions.First(a => a.Id == id).Title.TrimEnd('…'), Foreground = Brushes.DimGray });
            body.Children.Add(row);
        }
        if (page == 0) body.Children.Add(Recognition());
        if (page == Pages.Length - 1)
        {
            var kofi = new Button
            {
                Content = "♥  Lingveil is free. Support it on Ko-fi", Foreground = new SolidColorBrush(Color.FromRgb(255, 94, 91)), Background = Brushes.Transparent,
                BorderThickness = new Thickness(0), Margin = new Thickness(0, 18, 0, 0), HorizontalAlignment = HorizontalAlignment.Center, Cursor = System.Windows.Input.Cursors.Hand,
            };
            kofi.Click += (_, _) => SettingsWindow.OpenUrl(SettingsWindow.KoFi);
            body.Children.Add(kofi);
        }
        back.Visibility = page > 0 ? Visibility.Visible : Visibility.Collapsed;
        skip.Visibility = page == Pages.Length - 1 ? Visibility.Hidden : Visibility.Visible;
        next.Content = page == Pages.Length - 1 ? "Start Using Lingveil" : "Next";
        dots.Children.Clear();
        for (int i = 0; i < Pages.Length; i++)
            dots.Children.Add(new Ellipse { Width = 6, Height = 6, Margin = new Thickness(3, 0, 3, 0), Fill = i == page ? SystemColors.HighlightBrush : new SolidColorBrush(Color.FromArgb(46, 0, 0, 0)) });
    }

    /// Windows needs no permissions; what matters is which languages it can read on screen.
    UIElement Recognition()
    {
        var langs = Ocr.Languages;
        var box = new Border { Background = new SolidColorBrush(Color.FromArgb(13, 0, 0, 0)), CornerRadius = new CornerRadius(10), Padding = new Thickness(12), Margin = new Thickness(0, 18, 0, 0), Width = 460 };
        var row = new DockPanel();
        var mark = new TextBlock { Text = langs.Count > 0 ? "✔" : "○", Foreground = langs.Count > 0 ? Brushes.SeaGreen : Brushes.Gray, Margin = new Thickness(0, 0, 8, 0) };
        row.Children.Add(mark);
        var more = new Button { Content = "Add languages…", Padding = new Thickness(8, 1, 8, 1) };
        more.Click += (_, _) => SettingsWindow.Open("ocr");
        DockPanel.SetDock(more, Dock.Right);
        row.Children.Add(more);
        row.Children.Add(new TextBlock
        {
            Text = langs.Count > 0 ? $"Reads text on screen in {string.Join(", ", langs.Select(l => new System.Globalization.CultureInfo(l).DisplayName.Split(' ')[0]).Distinct())}" : "No text recognition language is installed yet",
            TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center,
        });
        box.Child = row;
        return box;
    }
}
