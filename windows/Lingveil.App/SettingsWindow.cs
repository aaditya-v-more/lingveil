using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Lingveil.Core;

namespace Lingveil.App;

/// Settings: General, Shortcuts, Models and Text recognition tabs, one fixed window size for
/// every tab, with ♥ Donate in the title area.
public sealed class SettingsWindow : Window
{
    static SettingsWindow? open;
    public const string KoFi = "https://ko-fi.com/aadityavmore";
    readonly Settings s = Settings.Current;
    readonly TabControl tabs = new();

    public static void Open(string? tab = null)
    {
        open ??= new SettingsWindow();
        open.Closed += (_, _) => open = null;
        if (tab != null) foreach (TabItem t in open.tabs.Items) if ((string)t.Tag == tab) open.tabs.SelectedItem = t;
        ((Window)open).Show();
        open.Activate();
    }

    SettingsWindow()
    {
        Title = "Lingveil Settings";
        Width = 680; Height = 600; ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Segoe UI"); FontSize = 13;
        var donate = new Button { Content = "♥ Donate", Padding = new Thickness(10, 3, 10, 3), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 12, 0) };
        donate.Click += (_, _) => OpenUrl(KoFi);
        tabs.Margin = new Thickness(12, 4, 12, 12);
        tabs.Items.Add(Tab("General", "general", General()));
        tabs.Items.Add(Tab("Shortcuts", "shortcuts", Shortcuts()));
        tabs.Items.Add(Tab("Models", "models", Models()));
        tabs.Items.Add(Tab("Text Recognition", "ocr", Recognition()));
        var root = new DockPanel();
        DockPanel.SetDock(donate, Dock.Top);
        root.Children.Add(donate);
        root.Children.Add(tabs);
        Content = root;
    }

    public static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    static TabItem Tab(string title, string tag, UIElement body) =>
        new() { Header = title, Tag = tag, Content = new ScrollViewer { Content = body, Padding = new Thickness(16), VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };

    static TextBlock Label(string t, bool head = false) => new()
    {
        Text = t, Margin = new Thickness(0, head ? 14 : 6, 0, 4), TextWrapping = TextWrapping.Wrap,
        FontWeight = head ? FontWeights.SemiBold : FontWeights.Normal,
    };

    static TextBlock Note(string t) => new() { Text = t, Foreground = Brushes.Gray, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 4) };

    UIElement General()
    {
        var p = new StackPanel();
        p.Children.Add(Label("Translate into", true));
        var target = new ComboBox { ItemsSource = Shared.Languages, DisplayMemberPath = "Name", SelectedItem = Shared.Languages.FirstOrDefault(l => l.Code == s.TargetLanguage.Code), Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        target.SelectionChanged += (_, _) => { if (target.SelectedItem is Language l) { s.Target = l.Code; s.Save(); } };
        p.Children.Add(target);

        p.Children.Add(Label("Engine", true));
        var engines = new (EngineKind, string)[]
        {
            (EngineKind.Auto, "Automatic (Google online, local model offline)"), (EngineKind.Google, "Google Translate"),
            (EngineKind.Local, "Local model (private, offline)"), (EngineKind.GoogleCloud, "Google Cloud (your API key)"),
            (EngineKind.Deepl, "DeepL (your API key)"), (EngineKind.Ollama, "Ollama or another local server"),
        };
        var engine = new ComboBox { ItemsSource = engines.Select(e => e.Item2).ToList(), SelectedIndex = Array.FindIndex(engines, e => e.Item1 == s.Engine), Width = 360, HorizontalAlignment = HorizontalAlignment.Left };
        engine.SelectionChanged += (_, _) => { s.Engine = engines[engine.SelectedIndex].Item1; s.Save(); };
        p.Children.Add(engine);
        p.Children.Add(Field("Google Cloud API key", s.GoogleCloudKey, v => s.GoogleCloudKey = v, secret: true));
        p.Children.Add(Field("DeepL API key", s.DeeplKey, v => s.DeeplKey = v, secret: true));
        p.Children.Add(Field("Ollama address", s.OllamaUrl, v => s.OllamaUrl = v));
        p.Children.Add(Field("Ollama model", s.OllamaModel, v => s.OllamaModel = v));

        p.Children.Add(Label("Look", true));
        var style = new ComboBox { ItemsSource = new[] { "Seamless (matches the app)", "Cards (rounded, readable)" }, SelectedIndex = (int)s.Style, Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        style.SelectionChanged += (_, _) => { s.Style = (OverlayStyle)style.SelectedIndex; s.Save(); };
        p.Children.Add(style);
        p.Children.Add(Check("Read exact app text with UI Automation", s.UseAccessibility, v => s.UseAccessibility = v));
        p.Children.Add(Check("Translate web pages by paragraph", s.WebParagraphs, v => s.WebParagraphs = v));
        p.Children.Add(Check("Hold Alt and rest the pointer on text to translate it", s.HoverWithAlt, v => s.HoverWithAlt = v));
        return p;
    }

    UIElement Field(string label, string value, Action<string> set, bool secret = false)
    {
        var row = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
        row.Children.Add(new TextBlock { Text = label, Foreground = Brushes.Gray, FontSize = 12 });
        if (secret)
        {
            var box = new PasswordBox { Password = value, Width = 360, HorizontalAlignment = HorizontalAlignment.Left };
            box.PasswordChanged += (_, _) => { set(box.Password); s.Save(); };
            row.Children.Add(box);
        }
        else
        {
            var box = new TextBox { Text = value, Width = 360, HorizontalAlignment = HorizontalAlignment.Left };
            box.LostFocus += (_, _) => { set(box.Text.Trim()); s.Save(); };
            row.Children.Add(box);
        }
        return row;
    }

    UIElement Check(string label, bool value, Action<bool> set)
    {
        var c = new CheckBox { Content = label, IsChecked = value, Margin = new Thickness(0, 8, 0, 0) };
        c.Click += (_, _) => { set(c.IsChecked == true); s.Save(); };
        return c;
    }

    UIElement Shortcuts()
    {
        var p = new StackPanel();
        p.Children.Add(Note("Type a shortcut such as Alt+Shift+T and press Enter. Leave it empty to turn the action off."));
        foreach (var a in Tray.Actions)
        {
            var grid = new Grid { Margin = new Thickness(0, 8, 0, 0) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.Children.Add(new TextBlock { Text = a.Title, VerticalAlignment = VerticalAlignment.Center });
            var box = new TextBox { Text = s.Shortcuts.GetValueOrDefault(a.Id, a.Default), Width = 180, HorizontalAlignment = HorizontalAlignment.Left };
            var status = new TextBlock { Foreground = Brushes.IndianRed, FontSize = 12, Margin = new Thickness(190, 3, 0, 0) };
            void Apply()
            {
                var text = box.Text.Trim();
                if (text.Length > 0 && Shortcut.Parse(text) is not { } sc) { status.Text = "Not a shortcut"; return; }
                status.Text = "";
                s.Shortcuts[a.Id] = text.Length == 0 ? "" : Shortcut.Parse(text)!.Value.ToString();
                box.Text = s.Shortcuts[a.Id];
                s.Save();
                Tray.RegisterShortcuts();
            }
            box.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) Apply(); };
            box.LostFocus += (_, _) => Apply();
            Grid.SetColumn(box, 1); Grid.SetColumn(status, 1);
            grid.Children.Add(box); grid.Children.Add(status);
            p.Children.Add(grid);
        }
        var reset = new Button { Content = "Restore Defaults", Margin = new Thickness(0, 16, 0, 0), Padding = new Thickness(10, 3, 10, 3), HorizontalAlignment = HorizontalAlignment.Left };
        reset.Click += (_, _) => { s.Shortcuts.Clear(); s.Save(); Tray.RegisterShortcuts(); Close(); Open("shortcuts"); };
        p.Children.Add(reset);
        return p;
    }

    readonly Dictionary<string, CancellationTokenSource> downloads = [];

    UIElement Models()
    {
        var p = new StackPanel();
        p.Children.Add(Note($"Run translation on this PC, private and offline. This PC has {Memory.TotalGB} GB of memory. " +
                            "Speed and accuracy come from measurements; untested ratings are estimates."));
        foreach (var m in LocalModel.Catalog) p.Children.Add(ModelRow(m));
        return p;
    }

    UIElement ModelRow(LocalModel m)
    {
        var card = new Border { BorderBrush = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 8, 0, 0) };
        var body = new StackPanel();
        var head = new StackPanel { Orientation = Orientation.Horizontal };
        var use = new RadioButton { GroupName = "model", IsChecked = s.LocalModel == m.Id, VerticalAlignment = VerticalAlignment.Center, ToolTip = "Use this model" };
        use.Checked += (_, _) => { s.LocalModel = m.Id; s.Save(); };
        head.Children.Add(use);
        head.Children.Add(new TextBlock { Text = m.Name, FontWeight = FontWeights.SemiBold, Margin = new Thickness(4, 0, 8, 0) });
        string? tag = m.Recommended ? m.Badge : m.Tested ? "Tested" : null;
        if (tag != null) head.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(30, 0, 120, 212)), CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 0, 6, 0), Child = new TextBlock { Text = tag, FontSize = 11 } });
        body.Children.Add(head);
        body.Children.Add(Note($"{m.Maker} · {m.Bytes / 1e9:0.0} GB · needs {m.RamGB} GB RAM · {m.Languages} languages · {m.License}"));
        body.Children.Add(new TextBlock { Text = m.Summary, TextWrapping = TextWrapping.Wrap, FontSize = 12 });
        string Dots(int n) => n <= 0 ? "not rated" : new string('●', n) + new string('○', 5 - n);
        body.Children.Add(Note($"Speed {Dots(m.Speed)}    Accuracy {Dots(m.Accuracy)}{(m.Tested ? "" : "   (estimate)")}"));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        var bar = new ProgressBar { Width = 200, Height = 6, Margin = new Thickness(8, 0, 0, 0), Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
        var status = new TextBlock { Margin = new Thickness(8, 0, 0, 0), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var button = new Button { Padding = new Thickness(10, 2, 10, 2) };
        void Refresh()
        {
            bool busy = downloads.ContainsKey(m.Id);
            button.Content = busy ? "Cancel" : ModelStore.IsInstalled(m) ? "Delete" : $"Download";
            bar.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        }
        button.Click += async (_, _) =>
        {
            if (downloads.TryGetValue(m.Id, out var running)) { running.Cancel(); return; }
            if (ModelStore.IsInstalled(m))
            {
                if (MessageBox.Show(this, $"Delete {m.Name} ({m.Bytes / 1e9:0.0} GB)?", "Lingveil", MessageBoxButton.OKCancel) == MessageBoxResult.OK) ModelStore.Delete(m);
                Refresh(); return;
            }
            var cts = downloads[m.Id] = new CancellationTokenSource();
            status.Text = ""; Refresh();
            try
            {
                await Task.Run(() => ModelStore.Download(m, new Progress<double>(v => { bar.Value = v * 100; status.Text = v >= 1 ? "Checking…" : $"{v:P0}"; }), cts.Token));
                status.Text = "Installed";
            }
            catch (OperationCanceledException) { status.Text = "Paused; download again to resume"; }
            catch (Exception e) { status.Text = e.Message; }
            downloads.Remove(m.Id);
            Refresh();
        };
        Refresh();
        actions.Children.Add(button); actions.Children.Add(bar); actions.Children.Add(status);
        body.Children.Add(actions);
        card.Child = body;
        return card;
    }

    UIElement Recognition()
    {
        var p = new StackPanel();
        p.Children.Add(Note("Windows reads text on screen one language at a time and needs that language's text recognition pack. " +
                            "Tick the languages you read on screen; Lingveil uses their packs together. Installing a pack asks for administrator approval."));
        foreach (var l in Shared.Languages)
        {
            var row = new Grid { Margin = new Thickness(0, 4, 0, 0) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(260) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            var check = new CheckBox { Content = l.Name, IsChecked = s.ReadLanguages.Contains(l.Code) || Ocr.HasPack(l.Code) && s.ReadLanguages.Count == 0 };
            check.Click += (_, _) =>
            {
                s.ReadLanguages.Remove(l.Code);
                if (check.IsChecked == true) s.ReadLanguages.Add(l.Code);
                s.Save();
            };
            var state = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
            var install = new Button { Content = "Install", Padding = new Thickness(8, 1, 8, 1), HorizontalAlignment = HorizontalAlignment.Left };
            void Refresh()
            {
                bool supported = Ocr.PackTags.ContainsKey(l.Code), has = Ocr.HasPack(l.Code);
                state.Text = !supported ? "Not available on Windows" : has ? "Installed" : "Not installed";
                state.Foreground = has ? Brushes.SeaGreen : Brushes.Gray;
                install.Visibility = supported && !has ? Visibility.Visible : Visibility.Collapsed;
            }
            install.Click += async (_, _) =>
            {
                install.IsEnabled = false; state.Text = "Installing…";
                await InstallPack(Ocr.PackTags[l.Code]);
                Ocr.Reset();
                if (!s.ReadLanguages.Contains(l.Code)) { s.ReadLanguages.Add(l.Code); s.Save(); check.IsChecked = true; }
                install.IsEnabled = true; Refresh();
            };
            Refresh();
            Grid.SetColumn(state, 1); Grid.SetColumn(install, 2);
            row.Children.Add(check); row.Children.Add(state); row.Children.Add(install);
            p.Children.Add(row);
        }
        return p;
    }

    /// Runs Add-WindowsCapability elevated; Windows shows its own approval prompt.
    static Task InstallPack(string tag) => Task.Run(() =>
    {
        try
        {
            var psi = new ProcessStartInfo("powershell.exe", $"-NoProfile -WindowStyle Hidden -Command \"Add-WindowsCapability -Online -Name 'Language.OCR~~~{tag}~0.0.1.0'\"")
            { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
            Process.Start(psi)?.WaitForExit();
        }
        catch { }   // declined at the approval prompt
    });
}
