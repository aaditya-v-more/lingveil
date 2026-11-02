using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Lingveil.Core;

namespace Lingveil.App;

/// Translation of the screen (or a picked area). With "Keep translating while you scroll"
/// on (the default) it follows the front window, click-through, until the same shortcut, the
/// ✕ on its bar, or another app coming forward (shared/SPEC.md §2.12b). With it off, the
/// overlay closes on a click, scroll, Esc, switching apps, or the same shortcut again.
public sealed class OneShot
{
    public static readonly OneShot Shared = new();
    OverlayWindow? window;
    int? escKey;
    DispatcherTimer? watch, windowTimer;
    CancellationTokenSource? cts;
    Follower? follower;
    FollowBar? bar;

    public bool IsShowing => window != null;
    public OverlayView? DebugView => window?.View;
    public string DebugTimings = "";
    /// The front window's title bar in the overlay's points, which isn't read aloud.
    public Rect? TitleBar { get; private set; }

    public void ToggleScreen()
    {
        if (IsShowing) { Dismiss(); return; }
        Run(Native.UnderCursor, null);
    }

    public async void Area()
    {
        Dismiss();
        if (await RegionPicker.Pick() is { } p) Run(p.Item1, p.Item2);
    }

    public async void Run(Native.Monitor mon, Int32Rect? requested, Action<List<Block>>? done = null)
    {
        Dismiss();
        Translation.Preconnect();
        bool follow = Settings.Current.FollowScroll;
        var fg = Native.GetForegroundWindow();
        var frontFrame = Native.ForegroundFrame();
        // Following stays with the app in front, like translating inside an app on a phone:
        // its window, not the whole screen (other windows changing would keep re-reading).
        Int32Rect? front = follow && requested == null && frontFrame is { } ff ? Native.Intersect(ff, mon.Bounds) : null;
        var area = Native.Intersect(front ?? requested ?? mon.Bounds, mon.Bounds) ?? mon.Bounds;
        TitleBar = frontFrame is { } tf ? new Rect((tf.X - area.X) / mon.Scale, (tf.Y - area.Y) / mon.Scale, tf.Width / mon.Scale, 32) : null;
        // Following: clicks and scrolls go through to the app underneath.
        var w = new OverlayWindow(area, interactive: !follow);
        if (!follow) w.View.OnDismiss = Dismiss;
        w.ShowFaded();
        window = w;
        ArmDismissal(esc: !follow);
        Tray.Busy(true);
        var target = Settings.Current.TargetLanguage;
        var c = cts = new CancellationTokenSource();
        Follower? f = null;
        if (follow)
        {
            f = follower = new Follower(w, mon, area);
            var b = bar = new FollowBar(area, mon, target, Dismiss);
            f.OnBusy = on => b.Busy = on;
            if (front != null) WatchWindow(fg, area, mon);
        }
        var slow = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
        slow.Tick += (_, _) => { slow.Stop(); if (window == w && w.View.Blocks.Count == 0) w.View.Status = "Translating…"; };
        slow.Start();
        var sw = Stopwatch.StartNew();
        try
        {
            MotionTracker.Token? token = null;
            if (f != null) { await f.Start(); token = f.Tracker.Begin(copyPixels: true); }
            if (window != w) return;
            var px = token?.Pixels ?? await Task.Run(() => Native.Capture(area));
            long captureMs = sw.ElapsedMilliseconds;
            // Focus rect in the snapshot's points: the front window's text goes first.
            Rect? focus = frontFrame is { } fr ? new Rect((fr.X - area.X) / mon.Scale, (fr.Y - area.Y) / mon.Scale, fr.Width / mon.Scale, fr.Height / mon.Scale) : null;
            var (items, blocks) = await Task.Run(async () =>
            {
                using var s = new Snapshot(px, mon.Scale);
                var items = await Pipeline.Items(s, Settings.Current.UseAccessibility ? () => Uia.Items(area, mon.Scale) : null);
                var blocks = await Pipeline.Blocks(items, s, target, focus, partial => w.Dispatcher.BeginInvoke(() =>
                {
                    if (window != w) return;
                    slow.Stop(); w.View.Status = null; w.View.Blocks = partial;
                }), c.Token);
                return (items, blocks);
            });
            DebugTimings = $"capture {captureMs} ms, {Pipeline.Timings}, total {sw.ElapsedMilliseconds} ms";
            Debug.Log("screen " + DebugTimings);
            if (window != w) return;
            slow.Stop();
            w.View.Status = null;
            if (f == null || token == null || !f.Adopt(blocks, Follower.Untranslated(items, blocks), token)) w.View.Blocks = blocks;
            if (blocks.Count == 0 && f != null) { w.View.Status = "Nothing to translate yet"; After(1.5, () => { if (w.View.Status == "Nothing to translate yet") w.View.Status = null; }); }
            else if (blocks.Count == 0) Flash(w, items.Count == 0 && Ocr.MissingHint() is { } hint ? hint : $"Nothing to translate into {target.Name}");
            else { Hud.Tip("overlay"); Hud.Used(); done?.Invoke(blocks); }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Debug.Log("screen error " + e);
            if (window == w) { slow.Stop(); Flash(w, e.Message); }
        }
        finally { Tray.Busy(false); }
    }

    static void After(double seconds, Action a)
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        t.Tick += (_, _) => { t.Stop(); a(); };
        t.Start();
    }

    void Flash(OverlayWindow w, string msg)
    {
        w.View.Status = msg;
        After(2, () => { if (window == w) Dismiss(); });
    }

    /// Moving or resizing the followed window starts over on its new frame; closing it ends.
    void WatchWindow(IntPtr hwnd, Int32Rect frame, Native.Monitor mon)
    {
        windowTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        windowTimer.Tick += (_, _) =>
        {
            if (follower == null) return;
            if (Native.FrameOf(hwnd) is not { } f || Native.Intersect(f, mon.Bounds) is not { } now) { Dismiss(); return; }
            if (Math.Abs(now.X - frame.X) + Math.Abs(now.Y - frame.Y) + Math.Abs(now.Width - frame.Width) + Math.Abs(now.Height - frame.Height) > 2 * mon.Scale)
                Run(mon, null);
        };
        windowTimer.Start();
    }

    void ArmDismissal(bool esc)
    {
        // While following, Esc belongs to the app being used.
        if (esc) escKey = HotKeys.Shared.Register(new Shortcut(0, Native.VK_ESCAPE), Dismiss);
        var fg = Native.GetForegroundWindow();
        bool keep = Environment.GetEnvironmentVariable("LINGVEIL_DEBUG_KEEP") != null;
        watch = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        watch.Tick += (_, _) =>
        {
            if (window == null) return;
            // Hold Alt to peek at the original.
            window.View.Opacity = Native.AltDown ? 0 : 1;
            // Switching to another app closes it.
            var now = Native.GetForegroundWindow();
            if (now != fg && now != IntPtr.Zero && !Native.IsOurs(now) && !keep) Dismiss();
        };
        watch.Start();
    }

    public void Dismiss()
    {
        if (Narrator.Shared.IsSpeaking && window != null) Narrator.Shared.Stop();
        cts?.Cancel(); cts = null;
        follower?.Stop(); follower = null;
        windowTimer?.Stop(); windowTimer = null;
        bar?.Close(); bar = null;
        HotKeys.Shared.Unregister(escKey); escKey = null;
        watch?.Stop(); watch = null;
        if (window is { } w)
        {
            window = null;
            w.FadeOut(Memory.Relieve);
            Hud.MaybeAsk();
        }
    }
}

/// Keeps a picked area translated while it changes (subtitles, chats, games) and while it
/// scrolls: the same following as a translated window (see Follower), on an area that stays
/// until it is stopped, whichever app is in front.
public sealed class Live
{
    public static readonly Live Shared = new();
    OverlayWindow? window;
    Follower? follower;
    int? stopKey;

    public bool IsRunning => window != null;
    public OverlayView? DebugView => window?.View;

    public async void Toggle()
    {
        if (IsRunning) { Stop(); return; }
        OneShot.Shared.Dismiss();
        if (await RegionPicker.Pick() is { } p) await Start(p.Item1, p.Item2);
    }

    public async Task Start(Native.Monitor m, Int32Rect r)
    {
        // The overlay goes up first; it is left out of capture.
        var w = new OverlayWindow(r, interactive: false);
        w.View.ShowBorder = true;
        w.ShowFaded();
        window = w;
        Translation.Preconnect();
        var f = follower = new Follower(w, m, r);
        stopKey = HotKeys.Shared.Register(new Shortcut(Native.MOD_ALT, Native.VK_ESCAPE), Stop);
        Tray.LiveMode(true);
        await f.Start();
        Debug.Log($"live started {r.X},{r.Y},{r.Width},{r.Height}");
        Hud.Tip("live");
    }

    public void Stop()
    {
        HotKeys.Shared.Unregister(stopKey); stopKey = null;
        follower?.Stop(); follower = null;
        window?.FadeOut(Memory.Relieve); window = null;
        Tray.LiveMode(false);
    }

    /// A coarse 64×64 brightness fingerprint of a frame, to tell frames that really changed.
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

/// Optional: hold Alt and rest the pointer on text to see it translated (§1, Hover).
public sealed class HoverWatcher
{
    public static readonly HoverWatcher Shared = new();
    DispatcherTimer? timer;
    Native.POINT lastPoint;
    int still;

    public void Update()
    {
        timer?.Stop(); timer = null;
        if (!Settings.Current.HoverWithAlt) return;
        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    void Tick()
    {
        bool onlyAlt = Native.AltDown && (Native.GetAsyncKeyState(0x10) & 0x8000) == 0 && (Native.GetAsyncKeyState(0x11) & 0x8000) == 0;
        if (!onlyAlt || OneShot.Shared.IsShowing) { still = 0; return; }
        var p = Native.Cursor;
        if (Math.Abs(p.X - lastPoint.X) + Math.Abs(p.Y - lastPoint.Y) > 3) { lastPoint = p; still = 0; return; }
        if (++still == 3) Bubble.Shared.UnderPointer(quiet: true);
    }
}
