using System.Collections.Concurrent;
using System.Windows;
using Lingveil.Core;
using SkiaSharp;

namespace Lingveil.App;

/// The running app: grabs the hotkeys, and on Translate Screen captures the screen, runs the
/// shared pipeline and paints the result in an overlay until it is closed. All X calls happen
/// on the thread that runs `Run`; work finished elsewhere is handed over with `Post`.
sealed class App
{
    // Default shortcuts (shared/SPEC.md §1): Alt+Shift+<key>.
    const string TranslateKey = "t";

    readonly IntPtr d;
    readonly int screen;
    readonly nuint root;
    readonly int width, height;
    readonly ConcurrentQueue<Action> queue = new();
    volatile bool quit;
    Session? session;
    byte translateCode, escapeCode;
    nuint activeWindowAtom;
    const int GraceMs = 400;   // the shortcut's own key and focus changes must not close what it just opened

    sealed class Session(Overlay overlay, Snapshot snap) : IDisposable
    {
        public Overlay Overlay { get; } = overlay;
        public Snapshot Snap { get; } = snap;
        public CancellationTokenSource Cancel { get; } = new();
        public bool Closed { get; set; }
        readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
        public long Age => clock.ElapsedMilliseconds;
        public void Dispose() { Closed = true; Cancel.Cancel(); Overlay.Dispose(); Snap.Dispose(); }
    }

    public App()
    {
        d = X11.XOpenDisplay(null);
        if (d == IntPtr.Zero) throw new LingveilException("Can't open the display (is DISPLAY set, and is this an X11 session?)");
        screen = X11.XDefaultScreen(d);
        root = X11.XRootWindow(d, screen);
        width = X11.XDisplayWidth(d, screen);
        height = X11.XDisplayHeight(d, screen);
        // A refused key grab (another program owns the shortcut) is reported, not fatal.
        X11.XSetErrorHandler((_, _) => 0);
    }

    void Post(Action a) => queue.Enqueue(a);

    static IEnumerable<uint> LockCombos() { foreach (var l in new uint[] { 0, X11.LockMask, X11.Mod2Mask, X11.LockMask | X11.Mod2Mask }) yield return l; }

    void Grab(byte code, uint mods) { foreach (var l in LockCombos()) X11.XGrabKey(d, code, mods | l, root, 1, X11.GrabModeAsync, X11.GrabModeAsync); }
    void Ungrab(byte code, uint mods) { foreach (var l in LockCombos()) X11.XUngrabKey(d, code, mods | l, root); }

    public unsafe int Run()
    {
        translateCode = X11.XKeysymToKeycode(d, X11.XStringToKeysym(TranslateKey));
        escapeCode = X11.XKeysymToKeycode(d, X11.XStringToKeysym("Escape"));
        Grab(translateCode, X11.Mod1Mask | X11.ShiftMask);
        WatchInput();
        X11.XSync(d, 0);
        Console.WriteLine($"Lingveil is running on {width}x{height}. Alt+Shift+T translates the screen; Esc closes it. Ctrl+C quits.");
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; quit = true; };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => { };

        var ev = stackalloc byte[192];   // XEvent is a 192-byte union
        while (!quit)
        {
            while (X11.XPending(d) > 0)
            {
                X11.XNextEvent(d, ev);
                int type = *(int*)ev;
                if (type == X11.KeyPress)
                {
                    uint state = *(uint*)(ev + 80), code = *(uint*)(ev + 84);
                    uint mods = state & (X11.ShiftMask | X11.ControlMask | X11.Mod1Mask);
                    if (code == translateCode && mods == (X11.Mod1Mask | X11.ShiftMask)) Toggle();
                    else if (code == escapeCode && session != null) Close("Esc");
                }
                else if (type == X11.GenericEvent)
                {
                    // XInput2 raw events: any click or scroll, wherever the pointer is.
                    if (X11.XGetEventData(d, ev) != 0)
                    {
                        if (*(int*)(ev + 36) == X11.XI_RawButtonPress && session != null && session.Age > GraceMs) Close("click or scroll");
                        X11.XFreeEventData(d, ev);
                    }
                }
                else if (type == X11.PropertyNotify && *(nuint*)(ev + 40) == activeWindowAtom && session != null && session.Age > GraceMs)
                    Close("another app came forward");
                else if (type == X11.Expose && session != null && *(nuint*)(ev + 32) == session.Overlay.Window)
                    session.Overlay.Repaint();
            }
            while (queue.TryDequeue(out var a))
                try { a(); } catch (Exception e) { Console.Error.WriteLine("error: " + e.Message); }
            Thread.Sleep(6);
        }
        Close();
        X11.XCloseDisplay(d);
        return 0;
    }

    /// Close the overlay on a click, a scroll or another app coming forward (shared/SPEC.md §1).
    unsafe void WatchInput()
    {
        activeWindowAtom = X11.XInternAtom(d, "_NET_ACTIVE_WINDOW", 0);
        X11.XSelectInput(d, root, (nint)X11.PropertyChangeMask);
        int major = 2, minor = 0;
        if (X11.XIQueryVersion(d, ref major, ref minor) != 0) return;   // no XInput2: Esc and the shortcut still close it
        // XIEventMask { int deviceid; int mask_len; unsigned char* mask } for all master devices.
        var mask = stackalloc byte[4];
        mask[X11.XI_RawButtonPress >> 3] = (byte)(1 << (X11.XI_RawButtonPress & 7));
        var em = stackalloc byte[16];
        *(int*)em = 1; *(int*)(em + 4) = 4; *(byte**)(em + 8) = mask;
        X11.XISelectEvents(d, root, em, 1);
    }

    void Toggle() { if (session != null) Close(); else Start(); }

    void Start()
    {
        try
        {
            // Capture first: our own overlay must not be in the picture.
            var snap = Capture.Grab(d, root, 0, 0, width, height, 1);
            var overlay = new Overlay(d, screen, root, 0, 0, width, height);
            var s = session = new Session(overlay, snap);
            Grab(escapeCode, 0);
            overlay.Show(Render(s, [], "Translating…"));
            _ = Task.Run(() => Translate(s));
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("error: " + e.Message);
            Close();
        }
    }

    void Close(string reason = "")
    {
        if (session == null) return;
        Console.WriteLine("closed" + (reason == "" ? "" : ": " + reason));
        Ungrab(escapeCode, 0);
        session.Dispose();
        session = null;
        X11.XFlush(d);
        Memory.Relieve();
    }

    async Task Translate(Session s)
    {
        try
        {
            var target = Settings.Current.TargetLanguage;
            var items = await Pipeline.Items(s.Snap);
            if (s.Closed) return;
            var blocks = await Pipeline.Blocks(items, s.Snap, target, null, sofar =>
            {
                var bmp = Render(s, sofar, null);   // painted off the X thread, shown on it
                Post(() => { if (!s.Closed) s.Overlay.Show(bmp); else bmp.Dispose(); });
            }, s.Cancel.Token);
            Console.WriteLine($"translated {blocks.Count} blocks ({Pipeline.Timings})");
            if (blocks.Count == 0)
            {
                var bmp = Render(s, [], items.Count == 0 ? "No text found" : "Nothing to translate");
                Post(() => { if (!s.Closed) s.Overlay.Show(bmp); else bmp.Dispose(); });
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Console.Error.WriteLine("error: " + e.Message);
            var bmp = Render(s, [], "Couldn't translate: " + e.Message);
            Post(() => { if (!s.Closed) s.Overlay.Show(bmp); else bmp.Dispose(); });
        }
    }

    /// The overlay's picture: the translated blocks, plus a pill with `pill` text if given.
    static SKBitmap Render(Session s, IReadOnlyList<Block> blocks, string? pill)
    {
        var bmp = new SKBitmap(new SKImageInfo(s.Overlay.Width, s.Overlay.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
        using var canvas = new SKCanvas(bmp);
        canvas.Clear(SKColors.Transparent);
        canvas.Scale((float)s.Snap.Scale);
        var bounds = new Rect(s.Snap.Size);
        if (blocks.Count > 0) Painter.DrawAll(canvas, blocks, bounds, Settings.Current.Style, s.Snap.Scale);
        if (pill != null) Painter.DrawPill(canvas, pill, bounds);
        return bmp;
    }
}
