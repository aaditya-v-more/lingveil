using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace Lingveil.Core;

/// A translation model run on this PC through the bundled llama.cpp server. The catalog
/// comes from shared/models.json.
public sealed record LocalModel(string Id, string Name, string Maker, string Summary, string Repo, string File, string Sha256,
                                long Bytes, int RamGB, int Languages, string Prompt, int Speed, int Accuracy, bool Recommended,
                                string? Badge, string License, IReadOnlySet<string>? Supported, bool Tested)
{
    public string Url => $"https://huggingface.co/{Repo}/resolve/main/{File}";
    public bool Supports(Language l) => Supported?.Contains(l.Code) ?? true;

    public static readonly IReadOnlyList<LocalModel> Catalog = Load();
    public static LocalModel? Named(string id) => Catalog.FirstOrDefault(m => m.Id == id);

    static List<LocalModel> Load()
    {
        var root = Shared.Models;
        var sets = root["languageSets"]!.AsObject();
        return root["models"]!.AsArray().Select(n =>
        {
            var s = n!["supported"];
            IReadOnlySet<string>? supported = s switch
            {
                null => null,
                JsonArray a => a.Select(x => x!.GetValue<string>()).ToHashSet(),
                JsonValue v when v.TryGetValue<string>(out var name) => sets[name]!.AsArray().Select(x => x!.GetValue<string>()).ToHashSet(),
                _ => null,
            };
            return new LocalModel(Str(n, "id"), Str(n, "name"), Str(n, "maker"), Str(n, "summary"), Str(n, "repo"), Str(n, "file"), Str(n, "sha256"),
                n["bytes"]!.GetValue<long>(), n["ramGB"]!.GetValue<int>(), n["languages"]!.GetValue<int>(), Str(n, "prompt"),
                n["speed"]!.GetValue<int>(), n["accuracy"]!.GetValue<int>(), n["recommended"]!.GetValue<bool>(),
                n["badge"]?.GetValue<string>(), Str(n, "license"), supported, n["tested"]?.GetValue<bool>() ?? false);
        }).ToList();
    }

    static string Str(JsonNode n, string k) => n[k]!.GetValue<string>();
}

/// Model files in %LOCALAPPDATA%\Lingveil\Models. Downloads resume from the staged
/// `<file>.part` and only count once the sha256 matches.
public static class ModelStore
{
    /// LINGVEIL_MODELS_DIR overrides the folder (tests, a bigger drive).
    public static string Folder { get; } = Directory.CreateDirectory(Environment.GetEnvironmentVariable("LINGVEIL_MODELS_DIR") ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lingveil", "Models")).FullName;

    public static string PathOf(LocalModel m) => Path.Combine(Folder, m.File);
    public static bool IsInstalled(LocalModel m) => System.IO.File.Exists(PathOf(m));

    static readonly HttpClient http = new() { Timeout = Timeout.InfiniteTimeSpan };

    /// Downloads `m`, reporting 0…1. Throws with a readable message on failure.
    public static async Task Download(LocalModel m, IProgress<double>? progress, CancellationToken ct)
    {
        var free = new DriveInfo(Path.GetPathRoot(Folder)!).AvailableFreeSpace;
        if (free < m.Bytes + 1_000_000_000) throw new LingveilException("Not enough free disk space");
        var part = PathOf(m) + ".part";
        long have = System.IO.File.Exists(part) ? new FileInfo(part).Length : 0;
        using var req = new HttpRequestMessage(HttpMethod.Get, m.Url);
        if (have > 0) req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(have, null);
        using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (resp.StatusCode == HttpStatusCode.OK) have = 0;   // server ignored the range
        else if (resp.StatusCode != HttpStatusCode.PartialContent) throw new LingveilException($"Download failed ({(int)resp.StatusCode})");
        long total = have + (resp.Content.Headers.ContentLength ?? m.Bytes);
        await using (var file = new FileStream(part, have > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
        await using (var body = await resp.Content.ReadAsStreamAsync(ct))
        {
            var buf = new byte[1 << 20];
            long done = have, lastReport = 0;
            int n;
            while ((n = await body.ReadAsync(buf, ct)) > 0)
            {
                await file.WriteAsync(buf.AsMemory(0, n), ct);
                done += n;
                if (done - lastReport > 8 << 20) { progress?.Report((double)done / total); lastReport = done; }
            }
        }
        progress?.Report(1);
        if (!(await Sha256(part, ct)).StartsWith(m.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            System.IO.File.Delete(part);
            throw new LingveilException("The download was damaged; try again");
        }
        System.IO.File.Move(part, PathOf(m), overwrite: true);
    }

    public static void Delete(LocalModel m)
    {
        if (Settings.Current.EffectiveLocalModel == m.Id) LlamaServer.Shared.Stop();
        System.IO.File.Delete(PathOf(m));
    }

    static async Task<string> Sha256(string path, CancellationToken ct)
    {
        await using var f = System.IO.File.OpenRead(path);
        return Convert.ToHexString(await SHA256.HashDataAsync(f, ct)).ToLowerInvariant();
    }
}

/// Runs the bundled llama.cpp server for the chosen model. It starts on first use and stops
/// after `idleStopSeconds`, so the model's memory is only held while translations happen.
/// The server is put in a Job object that kills it when this app's last handle to the job
/// closes, which Windows does even when the app crashes, so it can never be orphaned.
public sealed class LlamaServer
{
    public static readonly LlamaServer Shared = new();

    readonly SemaphoreSlim gate = new(1, 1);
    Process? process;
    string? modelId;
    int port;
    DateTime lastUse = DateTime.UtcNow;
    readonly Dictionary<string, DateTime> failedAt = [];
    CancellationTokenSource? idle;
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(2) };

    public static string Binary => Path.Combine(AppContext.BaseDirectory, "llama", "llama-server.exe");
    public static bool Available => System.IO.File.Exists(Binary);
    static int IdleStopSeconds => Core.Shared.Models["server"]!["idleStopSeconds"]!.GetValue<int>();
    public static int Parallel => Core.Shared.Models["server"]!["parallel"]!.GetValue<int>();

    /// Base URL of a server running `m`, starting it if needed. Concurrent callers share one
    /// start; a model that failed to start isn't retried for 30 seconds.
    public async Task<Uri> Endpoint(LocalModel m, CancellationToken ct)
    {
        lastUse = DateTime.UtcNow;
        await gate.WaitAsync(ct);
        try
        {
            if (process is { HasExited: false } && modelId == m.Id) return new Uri($"http://127.0.0.1:{port}/");
            if (failedAt.TryGetValue(m.Id, out var f) && DateTime.UtcNow - f < TimeSpan.FromSeconds(30))
                throw new LingveilException($"{m.Name} could not start");
            StopNow();
            try { return await Launch(m, ct); }
            catch { failedAt[m.Id] = DateTime.UtcNow; StopNow(); throw; }
        }
        finally { gate.Release(); }
    }

    async Task<Uri> Launch(LocalModel m, CancellationToken ct)
    {
        if (!Available) throw new LingveilException("The local model server is missing from this install");
        var file = ModelStore.PathOf(m);
        if (!System.IO.File.Exists(file)) throw new LingveilException($"Download {m.Name} in Settings → Models first");
        port = FreePort();
        var psi = new ProcessStartInfo(Binary)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = false, RedirectStandardError = false,
        };
        // Implicit Vulkan layers from other software (AMD switchable graphics, capture hooks)
        // can hang device setup on hybrid laptops; the server needs none of them.
        psi.Environment["VK_LOADER_LAYERS_DISABLE"] = "~implicit~";
        foreach (var a in Core.Shared.Models["server"]!["args"]!.AsArray()) psi.ArgumentList.Add(a!.GetValue<string>());
        // Per prompt family: chat families need --jinja; TranslateGemma runs with its own template off.
        foreach (var a in Core.Shared.Models["prompts"]![m.Prompt]!["serverArgs"]?.AsArray() ?? []) psi.ArgumentList.Add(a!.GetValue<string>());
        foreach (var a in new[] { "-m", file, "--host", "127.0.0.1", "--port", port.ToString(), "-t", Math.Max(2, Environment.ProcessorCount / 2).ToString() })
            psi.ArgumentList.Add(a);
        var p = Process.Start(psi) ?? throw new LingveilException($"{m.Name} could not start");
        Job.Add(p);
        try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
        process = p; modelId = m.Id;
        var baseUri = new Uri($"http://127.0.0.1:{port}/");
        // Wait for the model to load (a few seconds the first time).
        for (int i = 0; i < 300 && !p.HasExited; i++)
        {
            try { using var r = await http.GetAsync(new Uri(baseUri, "health"), ct); if (r.StatusCode == HttpStatusCode.OK) { ArmIdleStop(); return baseUri; } }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested) { }
            await Task.Delay(100, ct);
        }
        throw new LingveilException($"{m.Name} could not start");
    }

    public void Touch() => lastUse = DateTime.UtcNow;

    public void Stop() { gate.Wait(); try { StopNow(); } finally { gate.Release(); } }

    void StopNow()
    {
        idle?.Cancel(); idle = null;
        try { if (process is { HasExited: false }) process.Kill(); } catch { }
        process?.Dispose();
        process = null; modelId = null;
    }

    void ArmIdleStop()
    {
        idle?.Cancel();
        var cts = idle = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(20), cts.Token); } catch { return; }
                // Idle long enough, or the PC is short of memory: give the model's memory back.
                if (DateTime.UtcNow - lastUse > TimeSpan.FromSeconds(IdleStopSeconds) || Memory.AvailableMB < 700)
                {
                    await gate.WaitAsync();
                    try { if (idle == cts) StopNow(); } finally { gate.Release(); }
                    return;
                }
            }
        });
    }

    /// Ends servers left behind by an earlier run (only possible if the job was bypassed).
    public static void CleanUpStale()
    {
        foreach (var p in Process.GetProcessesByName("llama-server"))
        {
            try { if (string.Equals(p.MainModule?.FileName, Binary, StringComparison.OrdinalIgnoreCase)) p.Kill(); } catch { }
            p.Dispose();
        }
    }

    static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        int port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }
}

/// A Job object that ends every process in it when this app exits, crashes or is killed.
public static class Job
{
    static readonly IntPtr handle = Create();

    public static void Add(Process p) => AssignProcessToJobObject(handle, p.Handle);

    static IntPtr Create()
    {
        var h = CreateJobObject(IntPtr.Zero, null);
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION { BasicLimitInformation = { LimitFlags = 0x2000 } };   // KILL_ON_JOB_CLOSE
        int size = Marshal.SizeOf(info);
        var ptr = Marshal.AllocHGlobal(size);
        Marshal.StructureToPtr(info, ptr, false);
        SetInformationJobObject(h, 9, ptr, (uint)size);   // JobObjectExtendedLimitInformation
        Marshal.FreeHGlobal(ptr);
        return h;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong A, B, C, D, E, F; }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string? name);
    [DllImport("kernel32", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
    [DllImport("kernel32", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}

public static class Memory
{
    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX { public uint Length, Load; public ulong TotalPhys, AvailPhys, TotalPage, AvailPage, TotalVirtual, AvailVirtual, AvailExtended; }
    [DllImport("kernel32")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);

    public static long AvailableMB { get { var m = new MEMORYSTATUSEX { Length = 64 }; GlobalMemoryStatusEx(ref m); return (long)(m.AvailPhys >> 20); } }
    public static int TotalGB { get { var m = new MEMORYSTATUSEX { Length = 64 }; GlobalMemoryStatusEx(ref m); return (int)Math.Round(m.TotalPhys / 1073741824.0); } }

    /// Captures pass through megabytes of buffers; once a translation closes, compact the
    /// heap and trim the working set so the idle app stays small.
    public static void Relieve() => Task.Delay(500).ContinueWith(_ =>
    {
        System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(2, GCCollectionMode.Forced, true, true);
        SetProcessWorkingSetSize(Process.GetCurrentProcess().Handle, -1, -1);
    });

    [DllImport("kernel32")] static extern bool SetProcessWorkingSetSize(IntPtr p, nint min, nint max);
}

/// One request per line, `server.parallel` at a time, using the family's prompt template.
public sealed class LocalTranslator(LocalModel model) : ITranslator
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(60) };

    public async Task<string[]> Translate(IReadOnlyList<string> texts, Language target, CancellationToken ct = default)
    {
        var baseUri = await LlamaServer.Shared.Endpoint(model, ct);
        var outp = texts.ToArray();
        using var slots = new SemaphoreSlim(LlamaServer.Parallel);
        await Task.WhenAll(texts.Select(async (t, i) =>
        {
            await slots.WaitAsync(ct);
            try { outp[i] = await One(t, target, baseUri, ct); }
            finally { slots.Release(); }
        }));
        LlamaServer.Shared.Touch();
        return outp;
    }

    async Task<string> One(string text, Language target, Uri baseUri, CancellationToken ct)
    {
        var prompt = Shared.Models["prompts"]![model.Prompt]!;
        var src = Detect.Guess(text);
        var srcName = new System.Globalization.CultureInfo(src).EnglishName;
        var content = prompt["template"]!.GetValue<string>()
            .Replace("{target}", target.Name).Replace("{targetCode}", target.AppleId).Replace("{targetChinese}", target.ChineseName)
            .Replace("{source}", srcName).Replace("{sourceCode}", src).Replace("{text}", text);
        int maxTokens = Math.Min(1024, text.Length * 4 + 48);
        var body = new JsonObject();
        foreach (var (k, v) in prompt["params"]!.AsObject()) body[k] = v?.DeepClone();
        string path;
        if (prompt["endpoint"]!.GetValue<string>() == "completion")
        {
            path = "completion";
            body["prompt"] = content; body["n_predict"] = maxTokens; body["cache_prompt"] = true;
        }
        else
        {
            path = "v1/chat/completions";
            foreach (var (k, v) in Shared.Models["server"]!["chatExtra"]!.AsObject()) body[k] = v?.DeepClone();
            body["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = content });
            body["max_tokens"] = maxTokens;
        }
        using var resp = await http.PostAsJsonAsync(new Uri(baseUri, path), body, ct);
        var obj = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct));
        var raw = obj?["content"]?.GetValue<string>() ?? obj?["choices"]?[0]?["message"]?["content"]?.GetValue<string>() ?? text;
        return Clean(raw);
    }

    /// Strips thinking blocks, quotes and labels that small models sometimes add.
    public static string Clean(string s)
    {
        var t = s;
        int i = t.IndexOf("</think>", StringComparison.Ordinal);
        if (i >= 0) t = t[(i + 8)..];
        t = t.Replace("<end_of_turn>", "").Trim();
        foreach (var prefix in new[] { "Translation:", "翻译：", "译文：" })
            if (t.StartsWith(prefix)) t = t[prefix.Length..].Trim();
        return t;
    }
}
