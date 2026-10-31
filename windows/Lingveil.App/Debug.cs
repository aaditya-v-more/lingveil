using System.Diagnostics;
using System.Windows;
using Lingveil.Core;

namespace Lingveil.App;

/// `LINGVEIL_DEBUG_DIR=<dir>`: writing "<action>[|x,y,w,h]" to <dir>\cmd.txt runs that action
/// for real (area/live use the rect, in physical pixels), waits for the result, then saves
/// the screen including the overlay to <dir>\<action>.png and what it found to
/// <dir>\<action>.txt. "stop" ends live mode and closes overlays. Log lines go to <dir>\log.txt.
public static class Debug
{
    static readonly string? Dir = Environment.GetEnvironmentVariable("LINGVEIL_DEBUG_DIR");
    static FileSystemWatcher? watcher;

    public static void Log(string s)
    {
        if (Dir == null) return;
        try { File.AppendAllText(Path.Combine(Dir, "log.txt"), $"{DateTime.Now:HH:mm:ss.fff} {s}\n"); } catch { }
    }

    public static void Listen()
    {
        if (Dir == null) return;
        Directory.CreateDirectory(Dir);
        watcher = new FileSystemWatcher(Dir, "cmd.txt") { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName, EnableRaisingEvents = true };
        FileSystemEventHandler h = (_, _) => Application.Current.Dispatcher.BeginInvoke(Run);
        watcher.Changed += h; watcher.Created += h;
    }

    static async void Run()
    {
        string cmd;
        try { cmd = File.ReadAllText(Path.Combine(Dir!, "cmd.txt")).Trim(); File.Delete(Path.Combine(Dir!, "cmd.txt")); }
        catch { return; }
        if (cmd.Length == 0) return;
        var parts = cmd.Split('|');
        var name = parts[0];
        if (parts.Length > 1 && parts[1].Split(',').Select(int.Parse).ToArray() is { Length: 4 } v) RegionPicker.DebugRect = new Int32Rect(v[0], v[1], v[2], v[3]);
        Log("cmd " + cmd);
        if (name == "stop") { Live.Shared.Stop(); OneShot.Shared.Dismiss(); return; }
        if (name == "memory")
        {
            var p = Process.GetCurrentProcess();
            File.WriteAllText(Path.Combine(Dir!, "memory.txt"), $"working set {p.WorkingSet64 >> 20} MB, private {p.PrivateMemorySize64 >> 20} MB, managed {GC.GetTotalMemory(false) >> 20} MB\n");
            return;
        }
        var sw = Stopwatch.StartNew();
        OneShot.Shared.DebugTimings = "";
        Tray.Perform(name);
        bool Done() => name switch
        {
            "screen" or "area" => OneShot.Shared.DebugTimings.Length > 0 || OneShot.Shared.DebugView?.Status?.StartsWith("Nothing") == true,
            "live" => Live.Shared.DebugView?.Blocks.Count > 0,
            _ => true,
        };
        for (int i = 0; i < 600 && !Done(); i++) await Task.Delay(50);
        var log = $"ready after {sw.ElapsedMilliseconds} ms\n{OneShot.Shared.DebugTimings}\n";
        var view = name == "live" ? Live.Shared.DebugView : OneShot.Shared.DebugView;
        foreach (var b in view?.Blocks ?? [])
            log += $"{(b.Item.FromUia ? "UIA" : "OCR")} {(int)b.Item.Rect.X},{(int)b.Item.Rect.Y} {Cut(b.Item.Text)} -> {Cut(b.Translation)}\n";
        await Task.Delay(300);
        // Save the monitor with our overlay in it: lift the capture exclusion for one frame.
        var overlays = Application.Current.Windows.OfType<OverlayWindow>().ToList();
        foreach (var o in overlays) Native.SetWindowDisplayAffinity(o.Handle, Native.WDA_NONE);
        await Task.Delay(100);
        var mon = Native.UnderCursor;
        using (var px = Native.Capture(mon.Bounds))
        using (var snap = new Snapshot(px, mon.Scale))
            Headless.Write(snap, [], Path.Combine(Dir!, name + ".png"));
        foreach (var o in overlays) Native.ExcludeFromCapture(o.Handle);
        File.WriteAllText(Path.Combine(Dir!, name + ".txt"), log);
    }

    static string Cut(string s) => (s.Length > 50 ? s[..50] : s).Replace('\n', ' ');
}
