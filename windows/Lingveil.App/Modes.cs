using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Lingveil.Core;

namespace Lingveil.App;

/// One-shot translation of the monitor (or a picked area): the overlay stays until a click,
/// scroll, Esc, switching apps, or the same shortcut again.
public sealed class OneShot
{
    public static readonly OneShot Shared = new();
    OverlayWindow? window;
    int? escKey;
    DispatcherTimer? watch;
    CancellationTokenSource? cts;
    Snapshot? snap;

    public bool IsShowing => window != null;
    public OverlayView? DebugView => window?.View;
    public string DebugTimings = "";

    public void ToggleScreen()
    {
        if (IsShowing) { Dismiss(); return; }
        var mon = Native.UnderCursor;
        Run(mon, mon.Bounds);
    }

    public async void Area()
    {
        Dismiss();
        if (await RegionPicker.Pick() is { } p) Run(p.Item1, p.Item2);
    }

    public void Run(Native.Monitor mon, Int32Rect area)
    {
        Dismiss();
        Translation.Preconnect();
        var front = Native.ForegroundFrame();
        var w = new OverlayWindow(area, interactive: true);
        w.View.OnDismiss = Dismiss;
        w.ShowFaded();
        window = w;
        ArmDismissal();
        Tray.Busy(true);
        var target = Settings.Current.TargetLanguage;
        var c = cts = new CancellationTokenSource();
        var slow = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
        slow.Tick += (_, _) => { slow.Stop(); if (window == w && w.View.Blocks.Count == 0) w.View.Status = "Translating…"; };
        slow.Start();
        _ = Task.Run(async () =>
        {
            var sw = Stopwatch.StartNew();
            try
            {
                var s = snap = new Snapshot(Native.Capture(area), mon.Scale);
                long captureMs = sw.ElapsedMilliseconds;
                // Focus rect in the snapshot's points: the front window's text goes first.
                Rect? focus = front is { } f ? new Rect((f.X - area.X) / mon.Scale, (f.Y - area.Y) / mon.Scale, f.Width / mon.Scale, f.Height / mon.Scale) : null;
                var items = await Pipeline.Items(s, Settings.Current.UseAccessibility ? () => Uia.Items(area, mon.Scale) : null);
                var blocks = await Pipeline.Blocks(items, s, target, focus, partial => w.Dispatcher.BeginInvoke(() =>
                {
                    if (window != w) return;
                    slow.Stop(); w.View.Status = null; w.View.Blocks = partial;
                }), c.Token);
                DebugTimings = $"capture {captureMs} ms, {Pipeline.Timings}, total {sw.ElapsedMilliseconds} ms";
                Debug.Log("screen " + DebugTimings);
                await w.Dispatcher.InvokeAsync(() =>
                {
                    if (window != w) return;
                    slow.Stop();
                    w.View.Status = null;
                    w.View.Blocks = blocks;
                    if (blocks.Count == 0) Flash(w, items.Count == 0 && Ocr.MissingHint() is { } hint ? hint : $"Nothing to translate into {target.Name}");
                });
            }
            catch (OperationCanceledException) { }
            catch (Exception e)
            {
                Debug.Log("screen error " + e);
                await w.Dispatcher.InvokeAsync(() => { if (window == w) { slow.Stop(); Flash(w, e.Message); } });
            }
            finally { await w.Dispatcher.InvokeAsync(() => Tray.Busy(false)); }
        });
    }

    void Flash(OverlayWindow w, string msg)
    {
        w.View.Status = msg;
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        t.Tick += (_, _) => { t.Stop(); if (window == w) Dismiss(); };
        t.Start();
    }

    void ArmDismissal()
    {
        escKey = HotKeys.Shared.Register(new Shortcut(0, Native.VK_ESCAPE), Dismiss);
        var fg = Native.GetForegroundWindow();
        watch = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        watch.Tick += (_, _) =>
        {
            if (window == null) return;
            // Hold Alt to peek at the original.
            window.View.Opacity = Native.AltDown ? 0 : 1;
            // Switching to another app closes it.
            var now = Native.GetForegroundWindow();
            if (now != fg && now != IntPtr.Zero && !Native.IsOurs(now)) Dismiss();
        };
        watch.Start();
    }

    public void Dismiss()
    {
        cts?.Cancel(); cts = null;
        HotKeys.Shared.Unregister(escKey); escKey = null;
        watch?.Stop(); watch = null;
        if (window is { } w)
        {
            window = null;
            w.FadeOut(() =>
            {
                snap?.Dispose(); snap = null;
                Memory.Relieve();
            });
        }
    }
}

/// Keeps an area translated while it changes (subtitles, chats, games). The area is read at
/// up to 4 frames a second and a 64×64 brightness fingerprint skips unchanged frames, so an
/// idle area costs almost nothing.
public sealed class Live
{
    public static readonly Live Shared = new();
    OverlayWindow? window;
    DispatcherTimer? timer;
    int? stopKey;
    Native.Monitor? mon;
    Int32Rect area;
    byte[] lastPrint = [];
    PixelBuffer? pending;
    DateTime lastChange;
    bool working;

    public bool IsRunning => window != null;
    public OverlayView? DebugView => window?.View;

    public async void Toggle()
    {
        if (IsRunning) { Stop(); return; }
        OneShot.Shared.Dismiss();
        if (await RegionPicker.Pick() is { } p) Start(p.Item1, p.Item2);
    }

    public void Start(Native.Monitor m, Int32Rect r)
    {
        mon = m; area = r;
        var w = new OverlayWindow(r, interactive: false);
        w.View.ShowBorder = true;
        w.ShowFaded();
        window = w;
        stopKey = HotKeys.Shared.Register(new Shortcut(Native.MOD_ALT, Native.VK_ESCAPE), Stop);
        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        timer.Tick += (_, _) => Tick();
        timer.Start();
        Tray.LiveMode(true);
        Debug.Log($"live started {r.X},{r.Y},{r.Width},{r.Height}");
    }

    public void Stop()
    {
        HotKeys.Shared.Unregister(stopKey); stopKey = null;
        timer?.Stop(); timer = null;
        window?.FadeOut(Memory.Relieve); window = null;
        pending?.Dispose(); pending = null;
        lastPrint = [];
        Tray.LiveMode(false);
    }

    void Tick()
    {
        if (window == null) return;
        var px = Native.Capture(area);
        var print = Fingerprint(px);
        if (!Differs(print, lastPrint)) { px.Dispose(); return; }
        lastPrint = print;
        pending?.Dispose();
        pending = px;
        lastChange = DateTime.UtcNow;
        if (!working) _ = Work();
    }

    async Task Work()
    {
        working = true;
        try
        {
            // Let scrolling or animation settle briefly before reading the text.
            while (DateTime.UtcNow - lastChange < TimeSpan.FromMilliseconds(250)) await Task.Delay(80);
            while (pending is { } px && IsRunning && mon is { } m)
            {
                pending = null;
                using var snap = new Snapshot(px, m.Scale);
                try
                {
                    var blocks = await Task.Run(async () =>
                    {
                        var items = await Pipeline.Items(snap);
                        return await Pipeline.Blocks(items, snap, Settings.Current.TargetLanguage);
                    });
                    Debug.Log($"live blocks {blocks.Count}");
                    if (IsRunning) window!.View.Blocks = blocks;
                }
                catch (Exception e) { Debug.Log("live error " + e.Message); }
            }
        }
        finally { working = false; }
    }

    public static byte[] Fingerprint(PixelBuffer px)
    {
        const int n = 64;
        var outp = new byte[n * n];
        var span = px.Span;
        int w = px.Width, h = px.Height;
        for (int gy = 0; gy < n; gy++)
        {
            int y = Math.Min(h - 1, gy * h / n + h / (2 * n));
            for (int gx = 0; gx < n; gx++)
            {
                int o = (y * w + Math.Min(w - 1, gx * w / n + w / (2 * n))) * 4;
                outp[gy * n + gx] = (byte)((span[o] + 2 * span[o + 1] + span[o + 2]) / 4);
            }
        }
        return outp;
    }

    public static bool Differs(byte[] a, byte[] b)
    {
        if (a.Length != b.Length) return true;
        int changed = 0;
        for (int i = 0; i < a.Length; i++) if (Math.Abs(a[i] - b[i]) > 12) changed++;
        return changed > 2;
    }
}
