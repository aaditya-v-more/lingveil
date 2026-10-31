using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows;
using Lingveil.Core;
using Forms = System.Windows.Forms;

namespace Lingveil.App;

/// The notification-area icon and its menu; the whole app lives here.
public static class Tray
{
    static Forms.NotifyIcon? icon;
    static Icon? idleIcon, busyIcon, liveIcon;
    static readonly Dictionary<string, int?> keys = [];

    public static readonly (string Id, string Title, string Default, Action Run)[] Actions =
    [
        ("screen", "Translate Screen", "Alt+Shift+T", () => OneShot.Shared.ToggleScreen()),
        ("area", "Translate Area…", "Alt+Shift+A", () => OneShot.Shared.Area()),
        ("live", "Live Translate Area…", "Alt+Shift+L", () => Live.Shared.Toggle()),
    ];

    public static int Run()
    {
        using var single = new Mutex(true, "Lingveil.SingleInstance", out bool first);
        if (!first) return 0;
        LlamaServer.CleanUpStale();
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += (_, _) =>
        {
            idleIcon = MakeIcon(Color.FromArgb(0, 120, 212)); busyIcon = MakeIcon(Color.FromArgb(0, 90, 160)); liveIcon = MakeIcon(Color.FromArgb(196, 43, 28));
            icon = new Forms.NotifyIcon { Icon = idleIcon, Text = "Lingveil", Visible = true, ContextMenuStrip = new Forms.ContextMenuStrip() };
            icon.ContextMenuStrip.Opening += (_, _) => BuildMenu(icon.ContextMenuStrip);
            icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) OneShot.Shared.ToggleScreen(); };
            BuildMenu(icon.ContextMenuStrip);
            RegisterShortcuts();
            Debug.Listen();
            // Load the OCR engines once in the background so the first shortcut is quick.
            _ = Task.Run(async () =>
            {
                try { using var px = new PixelBuffer(64, 32); px.Span.Fill(255); await Ocr.Recognize(px, 0); } catch { }
                Memory.Relieve();
            });
        };
        app.Exit += (_, _) => { LlamaServer.Shared.Stop(); if (icon != null) icon.Visible = false; };
        app.Run();
        return 0;
    }

    public static void Perform(string id) => Actions.FirstOrDefault(a => a.Id == id).Run?.Invoke();

    static void RegisterShortcuts()
    {
        foreach (var k in keys.Values) HotKeys.Shared.Unregister(k);
        keys.Clear();
        var failed = new List<string>();
        foreach (var a in Actions)
        {
            var text = Settings.Current.Shortcuts.GetValueOrDefault(a.Id, a.Default);
            if (Shortcut.Parse(text) is not { } s) continue;
            var id = HotKeys.Shared.Register(s, a.Run);
            keys[a.Id] = id;
            if (id == null) failed.Add(text);
            Debug.Log($"shortcut {a.Id} {text} {(id == null ? "taken" : "ok")}");
        }
        if (failed.Count > 0) icon?.ShowBalloonTip(4000, "Lingveil", $"{string.Join(", ", failed)} is already used by another app.", Forms.ToolTipIcon.Warning);
    }

    static void BuildMenu(Forms.ContextMenuStrip m)
    {
        m.Items.Clear();
        foreach (var a in Actions)
        {
            var item = new Forms.ToolStripMenuItem(a.Title, null, (_, _) => a.Run())
            {
                ShortcutKeyDisplayString = Settings.Current.Shortcuts.GetValueOrDefault(a.Id, a.Default),
                Checked = a.Id == "live" && Live.Shared.IsRunning,
            };
            m.Items.Add(item);
        }
        m.Items.Add(new Forms.ToolStripSeparator());

        var s = Settings.Current;
        var target = new Forms.ToolStripMenuItem("Translate Into");
        foreach (var l in Shared.Languages)
            target.DropDownItems.Add(new Forms.ToolStripMenuItem(l.Name, null, (_, _) => { s.Target = l.Code; s.Save(); }) { Checked = s.TargetLanguage.Code == l.Code });
        m.Items.Add(target);

        var engine = new Forms.ToolStripMenuItem("Engine");
        foreach (var (kind, title) in new[]
        {
            (EngineKind.Auto, "Automatic (Google online, local model offline)"), (EngineKind.Google, "Google Translate"),
            (EngineKind.Local, "Local model (private, offline)"), (EngineKind.GoogleCloud, "Google Cloud (your API key)"),
            (EngineKind.Deepl, "DeepL (your API key)"), (EngineKind.Ollama, "Ollama or another local server"),
        })
            engine.DropDownItems.Add(new Forms.ToolStripMenuItem(title, null, (_, _) => { s.Engine = kind; s.Save(); }) { Checked = s.Engine == kind });
        m.Items.Add(engine);

        var style = new Forms.ToolStripMenuItem("Style");
        style.DropDownItems.Add(new Forms.ToolStripMenuItem("Seamless (matches the app)", null, (_, _) => { s.Style = OverlayStyle.Seamless; s.Save(); }) { Checked = s.Style == OverlayStyle.Seamless });
        style.DropDownItems.Add(new Forms.ToolStripMenuItem("Cards (rounded, readable)", null, (_, _) => { s.Style = OverlayStyle.Card; s.Save(); }) { Checked = s.Style == OverlayStyle.Card });
        m.Items.Add(style);

        m.Items.Add(new Forms.ToolStripSeparator());
        m.Items.Add(new Forms.ToolStripMenuItem("Quit Lingveil", null, (_, _) => { Live.Shared.Stop(); OneShot.Shared.Dismiss(); Application.Current.Shutdown(); }));
    }

    public static void Busy(bool on) { if (icon != null && !Live.Shared.IsRunning) icon.Icon = on ? busyIcon : idleIcon; }
    public static void LiveMode(bool on) { if (icon != null) icon.Icon = on ? liveIcon : idleIcon; }

    /// A small rounded tile with "文A", drawn at runtime so no icon file is needed yet.
    static Icon MakeIcon(Color fill)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using var path = new GraphicsPath();
            int r = 8;
            path.AddArc(0, 0, r, r, 180, 90); path.AddArc(31 - r, 0, r, r, 270, 90);
            path.AddArc(31 - r, 31 - r, r, r, 0, 90); path.AddArc(0, 31 - r, r, r, 90, 90);
            path.CloseFigure();
            using var b = new SolidBrush(fill);
            g.FillPath(b, path);
            using var f = new Font("Segoe UI", 12, System.Drawing.FontStyle.Bold, GraphicsUnit.Pixel);
            using var f2 = new Font("Yu Gothic UI", 13, System.Drawing.FontStyle.Bold, GraphicsUnit.Pixel);
            g.DrawString("文", f2, Brushes.White, 1, 3);
            g.DrawString("A", f, Brushes.White, 16, 13);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }
}
