using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Lingveil.Core;

namespace Lingveil.App;

/// Settings: General, Shortcuts, Models, Voices and Text recognition tabs, one fixed window
/// size for every tab, with ♥ Donate in the title area.
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
        tabs.Items.Add(Tab("Voices", "voices", VoicesTab()));
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
        p.Children.Add(Check("Keep translating while you scroll and use the app", s.FollowScroll, v => s.FollowScroll = v));
        p.Children.Add(Check("Translate web pages by paragraph", s.WebParagraphs, v => s.WebParagraphs = v));
        p.Children.Add(Check("Hold Alt and rest the pointer on text to translate it", s.HoverWithAlt, v => { s.HoverWithAlt = v; HoverWatcher.Shared.Update(); }));

        p.Children.Add(Label("Help", true));
        var tour = new Button { Content = "Show Tutorial", Padding = new Thickness(10, 3, 10, 3), HorizontalAlignment = HorizontalAlignment.Left };
        tour.Click += (_, _) => { Hud.ResetTips(); Tutorial.Show(); };
        p.Children.Add(tour);
        p.Children.Add(Note("Also shows the one-time tips again."));
        return p;
    }

    // MARK: voices

    readonly Dictionary<string, CancellationTokenSource> voiceDownloads = [];
    StackPanel? voicesPanel;

    UIElement VoicesTab()
    {
        voicesPanel = new StackPanel();
        FillVoices();
        return voicesPanel;
    }

    void FillVoices()
    {
        var p = voicesPanel!;
        p.Children.Clear();
        var plugins = Plugins.Load();
        var installed = VoiceStore.Installed.ToList();
        var engines = new List<(string Id, string Title)> { ("system", "Windows voices") };
        engines.AddRange(plugins.Select(x => (x.Name, x.Name + " voices")));
        engines.AddRange(installed.Select(m => ("model:" + m.Id, m.Name)));
        if (!engines.Any(e => e.Id == s.VoiceEngine)) { s.VoiceEngine = "system"; s.Save(); }

        p.Children.Add(Label("Read with", true));
        var engine = new ComboBox { ItemsSource = engines.Select(e => e.Title).ToList(), SelectedIndex = engines.FindIndex(e => e.Id == s.VoiceEngine), Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        engine.SelectionChanged += (_, _) => { if (engine.SelectedIndex >= 0) { s.VoiceEngine = engines[engine.SelectedIndex].Id; s.Save(); Dispatcher.BeginInvoke(FillVoices); } };
        p.Children.Add(engine);

        p.Children.Add(Label("Speed", true));
        var speedRow = new StackPanel { Orientation = Orientation.Horizontal };
        var speed = new Slider { Minimum = 0.5, Maximum = 3, TickFrequency = 0.1, IsSnapToTickEnabled = true, Value = s.SpeechSpeed, Width = 260 };
        var speedText = new TextBlock { Text = $"{s.SpeechSpeed:0.0}×", Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        speed.ValueChanged += (_, e) => { s.SpeechSpeed = Math.Round(e.NewValue, 1); speedText.Text = $"{s.SpeechSpeed:0.0}×"; s.Save(); };
        speedRow.Children.Add(speed); speedRow.Children.Add(speedText);
        p.Children.Add(speedRow);

        var target = s.TargetLanguage;
        var b = VoiceModel.Base(Voices.Normalize(target.Code));
        p.Children.Add(Label($"Voice for {target.Name}", true));
        var voiceRow = new StackPanel { Orientation = Orientation.Horizontal };
        var hear = new Button { Content = "▶ Hear it", Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(8, 0, 0, 0) };
        hear.Click += (_, _) => Preview(target);
        if (s.VoiceEngine == "system")
        {
            var voices = Voices.SystemVoices(target.Code);
            if (voices.Count == 0) p.Children.Add(Note($"No {target.Name} voice is installed. Add one in Windows Settings → Time & language → Speech."));
            else
            {
                var chosen = Voices.SystemVoice(target.Code);
                var box = new ComboBox { ItemsSource = voices.Select(v => $"{v.DisplayName} ({v.Language})").ToList(), SelectedIndex = voices.ToList().FindIndex(v => v.Id == chosen?.Id), Width = 320 };
                box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) { s.VoiceIds[b] = voices[box.SelectedIndex].Id; s.Save(); } };
                voiceRow.Children.Add(box); voiceRow.Children.Add(hear);
                p.Children.Add(voiceRow);
            }
            var more = new Button { Content = "Add more voices…", Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
            more.Click += (_, _) => OpenUrl("ms-settings:speech");
            p.Children.Add(more);
        }
        else if (plugins.FirstOrDefault(x => x.Name == s.VoiceEngine) is { } plugin)
        {
            var voices = Plugins.Voices(plugin).Where(v => v.Language.ToLowerInvariant().StartsWith(b)).ToList();
            if (voices.Count == 0) p.Children.Add(Note($"{plugin.Name} has no {target.Name} voice; the Windows voice is used instead."));
            else
            {
                var key = $"{plugin.Name}|{b}";
                var chosen = Voices.PluginVoice(plugin, b);
                var box = new ComboBox { ItemsSource = voices.Select(v => $"{v.Name} ({v.Language}{(v.Gender != null ? ", " + v.Gender : "")})").ToList(), SelectedIndex = voices.FindIndex(v => v.Id == chosen), Width = 320 };
                box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) { s.VoiceIds[key] = voices[box.SelectedIndex].Id; s.Save(); } };
                voiceRow.Children.Add(box); voiceRow.Children.Add(hear);
                p.Children.Add(voiceRow);
            }
        }
        else if (installed.FirstOrDefault(m => "model:" + m.Id == s.VoiceEngine) is { } vm)
        {
            var reader = VoiceStore.ModelFor(b, vm);
            voiceRow.Children.Add(new TextBlock
            {
                Text = reader == null ? $"{vm.Name} has no {target.Name} voice; the Windows voice is used instead."
                    : reader.Id == vm.Id ? $"{vm.Name} reads {target.Name}." : $"{vm.Name} has no {target.Name} voice; {reader.Name} reads it.",
                VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 440,
            });
            voiceRow.Children.Add(hear);
            p.Children.Add(voiceRow);
        }
        p.Children.Add(Note("Text in other languages is read with the best voice installed for that language. Change the target language in General."));

        p.Children.Add(Label("Voices that run on this PC", true));
        p.Children.Add(Note("Open-source voices, downloaded once and run offline. Ratings are measured: speed from how long a sentence takes to make, clarity from how well a speech recognizer understands it."));
        foreach (var m in VoiceCatalog.Models.Where(m => m.Recommended)) p.Children.Add(VoiceRow(m));
        p.Children.Add(Label("More voices", true));
        foreach (var m in VoiceCatalog.Models.Where(m => !m.Recommended)) p.Children.Add(VoiceRow(m));
        p.Children.Add(Label("Voice plugins", true));
        p.Children.Add(Note($"Other voice engines can be added in {Plugins.File} (the same engines.json format as Earmark): an HTTP server that returns WAV, or a command."));
    }

    static void Preview(Language target)
    {
        var sample = new Dictionary<string, string>
        {
            ["en"] = "This is how Lingveil reads your screen aloud.", ["hi"] = "लिंगवील आपकी स्क्रीन इसी तरह पढ़कर सुनाता है।",
            ["ja"] = "Lingveil は画面をこのように読み上げます。", ["es"] = "Así es como Lingveil lee tu pantalla en voz alta.",
            ["fr"] = "Voici comment Lingveil lit votre écran à voix haute.", ["de"] = "So liest Lingveil deinen Bildschirm vor.",
            ["zh"] = "Lingveil 会这样朗读你的屏幕。", ["ko"] = "Lingveil은 화면을 이렇게 읽어 줍니다.",
        }.GetValueOrDefault(VoiceModel.Base(target.Code), "Lingveil");
        Narrator.Shared.Read([new Segment(sample, null, target.Code)], _ => { });
    }

    UIElement VoiceRow(VoiceModel m)
    {
        var card = new Border { BorderBrush = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 8, 0, 0) };
        var body = new StackPanel();
        var head = new StackPanel { Orientation = Orientation.Horizontal };
        head.Children.Add(new TextBlock { Text = m.Name, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 8, 0) });
        head.Children.Add(new TextBlock { Text = m.Maker, Foreground = Brushes.Gray, Margin = new Thickness(0, 0, 8, 0) });
        string? tag = m.Recommended ? m.Badge : m.Tested ? "Tested" : null;
        if (s.VoiceEngine == "model:" + m.Id) tag = "In use";
        if (tag != null) head.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(30, 0, 120, 212)), CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 0, 6, 0), Child = new TextBlock { Text = tag, FontSize = 11 } });
        body.Children.Add(head);
        body.Children.Add(new TextBlock { Text = m.Summary, TextWrapping = TextWrapping.Wrap, FontSize = 12 });
        string Dots(int n) => n <= 0 ? "not rated" : new string('●', n) + new string('○', 5 - n);
        var langs = m.Languages.Count > 4 ? $"{m.Languages.Count} languages" : string.Join(", ", m.Languages.Select(c => Shared.Language(c).Name));
        body.Children.Add(Note($"Speed {Dots(m.Speed)}    Clarity {Dots(m.Clarity)}    {m.Bytes / 1e6:0} MB · {langs} · {m.License}"));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        var bar = new ProgressBar { Width = 200, Height = 6, Margin = new Thickness(8, 0, 0, 0), Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
        var status = new TextBlock { Margin = new Thickness(8, 0, 0, 0), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var button = new Button { Padding = new Thickness(10, 2, 10, 2) };
        var use = new Button { Content = "Use", Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(8, 0, 0, 0) };
        use.Click += (_, _) => { s.VoiceEngine = "model:" + m.Id; s.Save(); FillVoices(); };
        void Refresh()
        {
            bool busy = voiceDownloads.ContainsKey(m.Id), has = VoiceStore.IsInstalled(m);
            button.Content = busy ? "Cancel" : has ? "Delete" : "Download";
            bar.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            use.Visibility = has && !busy && s.VoiceEngine != "model:" + m.Id ? Visibility.Visible : Visibility.Collapsed;
        }
        button.Click += async (_, _) =>
        {
            if (voiceDownloads.TryGetValue(m.Id, out var running)) { running.Cancel(); return; }
            if (VoiceStore.IsInstalled(m))
            {
                if (MessageBox.Show(this, $"Delete {m.Name} ({m.Bytes / 1e6:0} MB)? You can download it again later.", "Lingveil", MessageBoxButton.OKCancel) == MessageBoxResult.OK)
                {
                    VoiceStore.Delete(m);
                    if (s.VoiceEngine == "model:" + m.Id) { s.VoiceEngine = "system"; s.Save(); }
                    FillVoices();
                }
                return;
            }
            var cts = voiceDownloads[m.Id] = new CancellationTokenSource();
            status.Text = ""; Refresh();
            try
            {
                await Task.Run(() => VoiceStore.Download(m, new Progress<double>(v => { bar.Value = v * 100; status.Text = $"{v:P0}"; }), cts.Token));
                voiceDownloads.Remove(m.Id);
                // The first voice downloaded is the one that reads.
                if (s.VoiceEngine == "system") { s.VoiceEngine = "model:" + m.Id; s.Save(); }
                FillVoices();
                return;
            }
            catch (OperationCanceledException) { status.Text = "Cancelled"; }
            catch (Exception e) { status.Text = e.Message; }
            voiceDownloads.Remove(m.Id);
            Refresh();
        };
        Refresh();
        actions.Children.Add(button); actions.Children.Add(use); actions.Children.Add(bar); actions.Children.Add(status);
        body.Children.Add(actions);
        card.Child = body;
        return card;
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
