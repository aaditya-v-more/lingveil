using System.Diagnostics;

namespace Lingveil.Core;

/// Keeps the model server from outliving the app. Windows uses a Job object; Linux has no
/// equivalent a parent can apply after the fact, so (like the Mac's guard process) a small
/// watcher outside the app's process tree ends the server once the app is gone.
public static class Job
{
    public static void Add(Process server)
    {
        try
        {
            var psi = new ProcessStartInfo("/bin/sh") { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in new[] { "-c", "while kill -0 \"$1\" 2>/dev/null && kill -0 \"$2\" 2>/dev/null; do sleep 1; done; kill \"$2\" 2>/dev/null", "lingveil-guard",
                                      Environment.ProcessId.ToString(), server.Id.ToString() })
                psi.ArgumentList.Add(a);
            Process.Start(psi)?.Dispose();
        }
        catch { }
    }
}

public static class Memory
{
    static long Field(string name)
    {
        try
        {
            foreach (var l in File.ReadLines("/proc/meminfo"))
                if (l.StartsWith(name + ":")) return long.Parse(l.Split(' ', StringSplitOptions.RemoveEmptyEntries)[1]);
        }
        catch { }
        return 0;
    }

    public static long AvailableMB => Field("MemAvailable") / 1024;
    public static int TotalGB => (int)Math.Round(Field("MemTotal") / 1048576.0);

    public static void Relieve() => Task.Delay(500).ContinueWith(_ =>
    {
        System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(2, GCCollectionMode.Forced, true, true);
    });
}
