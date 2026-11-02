using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Lingveil.Core;

/// An open-source narration model, run on this PC by the TTS helper through sherpa-onnx.
/// The catalog and ratings live in shared/voices.json (the Mac app reads it too).
public sealed record VoiceModel(string Id, string Name, string Maker, string Kind, string Summary, string Url, string Sha256, long Bytes,
                                IReadOnlyList<string> Languages, IReadOnlyDictionary<string, int> Speakers, string License, bool Recommended,
                                int Speed, int Clarity, bool Tested, string? Badge, IReadOnlyDictionary<string, double>? ErrorRate)
{
    public static string Base(string l) => new(l.ToLowerInvariant().TakeWhile(c => c != '-' && c != '_').ToArray());
    public bool Speaks(string language) => Languages.Contains(Base(language));
    public int Speaker(string language) =>
        Speakers.TryGetValue(language.ToLowerInvariant(), out var s) ? s : Speakers.TryGetValue(Base(language), out s) ? s : Speakers.GetValueOrDefault("default");
    public double? Error(string lang) => ErrorRate != null && ErrorRate.TryGetValue(lang, out var e) ? e : null;
}

public static class VoiceCatalog
{
    public record Runtime(string Url, string Sha256, long Bytes, IReadOnlyList<string> Keep);

    static readonly JsonObject Root = JsonNode.Parse(File.ReadAllText(Shared.Find("voices.json")))!.AsObject();

    public static readonly IReadOnlyList<VoiceModel> Models = Root["models"]!.AsArray().Select(n =>
    {
        var o = n!.AsObject();
        string S(string k) => o[k]?.GetValue<string>() ?? "";
        int I(string k) => o[k]?.GetValue<int>() ?? 0;
        return new VoiceModel(S("id"), S("name"), S("maker"), S("kind"), S("summary"), S("url"), S("sha256"), o["bytes"]!.GetValue<long>(),
            o["languages"]!.AsArray().Select(l => l!.GetValue<string>()).ToList(),
            o["speakers"]!.AsObject().ToDictionary(kv => kv.Key, kv => kv.Value!.GetValue<int>()),
            S("license"), o["recommended"]?.GetValue<bool>() ?? false, I("speed"), I("clarity"), o["tested"]?.GetValue<bool>() ?? false,
            o["badge"]?.GetValue<string>(),
            o["errorRate"]?.AsObject().ToDictionary(kv => kv.Key, kv => kv.Value!.GetValue<double>()));
    }).ToList();

    public static readonly Runtime? WinRuntime = Root["runtime"]?["win-x64"] is JsonObject r
        ? new Runtime(r["url"]!.GetValue<string>(), r["sha256"]!.GetValue<string>(), r["bytes"]!.GetValue<long>(), r["keep"]!.AsArray().Select(k => k!.GetValue<string>()).ToList())
        : null;
}

/// Narration models and the sherpa-onnx runtime (~25 MB) are downloaded on demand into
/// %LOCALAPPDATA%\Lingveil\Voices, so nothing of them ships with the app.
public static class VoiceStore
{
    public static string Folder { get; } = Directory.CreateDirectory(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lingveil", "Voices")).FullName;
    public static string RuntimeDir => Path.Combine(Folder, "runtime");
    public static string PathOf(VoiceModel m) => Path.Combine(Folder, m.Id);
    public static bool RuntimeInstalled => File.Exists(Path.Combine(RuntimeDir, "sherpa-onnx-c-api.dll"));
    public static bool IsInstalled(VoiceModel m) => Directory.Exists(PathOf(m));
    public static IEnumerable<VoiceModel> Installed => VoiceCatalog.Models.Where(IsInstalled);

    /// Downloads the runtime (first time) and the model, checking each against its sha256.
    public static async Task Download(VoiceModel m, IProgress<double> progress, CancellationToken ct)
    {
        var rt = VoiceCatalog.WinRuntime ?? throw new LingveilException("No voice runtime for Windows");
        bool needRuntime = !RuntimeInstalled;
        double total = m.Bytes + (needRuntime ? rt.Bytes : 0);
        if (needRuntime)
        {
            await Fetch(rt.Url, rt.Sha256, new Progress<double>(p => progress.Report(p * rt.Bytes / total)), dir =>
            {
                if (Directory.Exists(RuntimeDir)) Directory.Delete(RuntimeDir, true);
                Directory.CreateDirectory(RuntimeDir);
                foreach (var k in rt.Keep)
                {
                    var src = Find(k, dir) ?? throw new LingveilException("The voice runtime is incomplete");
                    File.Move(src, Path.Combine(RuntimeDir, Path.GetFileName(k)));
                }
            }, ct);
        }
        double before = needRuntime ? rt.Bytes : 0;
        await Fetch(m.Url, m.Sha256, new Progress<double>(p => progress.Report((before + p * m.Bytes) / total)), dir =>
        {
            // The archive holds one folder named after the model.
            var inner = Path.Combine(dir, m.Id);
            var src = Directory.Exists(inner) ? inner : dir;
            if (Directory.Exists(PathOf(m))) Directory.Delete(PathOf(m), true);
            Directory.Move(src, PathOf(m));
        }, ct);
    }

    public static void Delete(VoiceModel m)
    {
        TtsHelper.StopAll();
        if (Directory.Exists(PathOf(m))) Directory.Delete(PathOf(m), true);
        // The runtime is only worth keeping while some model uses it.
        if (!Installed.Any() && Directory.Exists(RuntimeDir)) Directory.Delete(RuntimeDir, true);
    }

    static string? Find(string relative, string dir)
    {
        var direct = Path.Combine(dir, relative);
        if (File.Exists(direct)) return direct;
        // Release archives wrap everything in a versioned top folder.
        return Directory.GetDirectories(dir).Select(d => Path.Combine(d, relative)).FirstOrDefault(File.Exists);
    }

    // Downloads take minutes; the translation client gives up after seconds.
    static readonly HttpClient http = new() { Timeout = Timeout.InfiniteTimeSpan };

    /// Downloads a .tar.bz2, checks it, unpacks it into a scratch folder (Windows' own tar)
    /// and hands that over.
    static async Task Fetch(string url, string sha256, IProgress<double> progress, Action<string> install, CancellationToken ct)
    {
        var tmp = Path.Combine(Folder, $".download-{Guid.NewGuid():N}.tar.bz2");
        var scratch = Path.Combine(Folder, $".unpack-{Guid.NewGuid():N}");
        try
        {
            using (var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct))
            {
                resp.EnsureSuccessStatusCode();
                long len = resp.Content.Headers.ContentLength ?? 0;
                await using var src = await resp.Content.ReadAsStreamAsync(ct);
                await using var dst = File.Create(tmp);
                var buf = new byte[1 << 16];
                long got = 0; int n;
                while ((n = await src.ReadAsync(buf, ct)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, n), ct);
                    got += n;
                    if (len > 0) progress.Report(Math.Min(1, (double)got / len));
                }
            }
            string hash;
            await using (var f = File.OpenRead(tmp)) hash = Convert.ToHexString(await SHA256.HashDataAsync(f, ct)).ToLowerInvariant();
            if (hash != sha256) throw new LingveilException("The download was damaged; try again");
            Directory.CreateDirectory(scratch);
            var tar = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "tar.exe"), $"-xjf \"{tmp}\" -C \"{scratch}\"")
            { CreateNoWindow = true, UseShellExecute = false })!;
            await tar.WaitForExitAsync(ct);
            if (tar.ExitCode != 0) throw new LingveilException("Couldn't unpack the download");
            ct.ThrowIfCancellationRequested();
            install(scratch);
        }
        finally
        {
            try { File.Delete(tmp); } catch { }
            try { if (Directory.Exists(scratch)) Directory.Delete(scratch, true); } catch { }
        }
    }

    /// The model that reads `language`: the chosen one, unless another downloaded model was
    /// measured clearly better in that language; if the chosen one doesn't speak it, the
    /// clearest that does; otherwise none, and the Windows voice reads it.
    public static VoiceModel? ModelFor(string language, VoiceModel chosen)
    {
        var lang = VoiceModel.Base(language);
        var others = Installed.Where(o => o.Speaks(lang) && o.Id != chosen.Id).ToList();
        if (chosen.Speaks(lang))
        {
            if (chosen.Error(lang) is not { } mine) return chosen;
            return others.Where(o => (o.Error(lang) ?? 1) < mine / 2).MinBy(o => o.Error(lang)) ?? chosen;
        }
        return others.MinBy(o => o.Error(lang) ?? 1 - o.Clarity / 10.0);
    }
}

/// One running TTS helper per model (`Lingveil.exe --tts`). The helper keeps the model
/// loaded between requests and quits by itself after two idle minutes, or as soon as
/// Lingveil goes away (its stdin closes), so a model never holds memory while idle.
public sealed class TtsHelper
{
    static readonly Dictionary<string, TtsHelper> running = [];
    readonly Process process;
    readonly SemaphoreSlim one = new(1, 1);

    public static TtsHelper For(VoiceModel m)
    {
        lock (running)
        {
            if (running.TryGetValue(m.Id, out var h) && !h.process.HasExited) return h;
            return running[m.Id] = new TtsHelper(m);
        }
    }

    public static void StopAll()
    {
        lock (running)
        {
            foreach (var h in running.Values) try { h.process.Kill(); } catch { }
            running.Clear();
        }
    }

    TtsHelper(VoiceModel m)
    {
        var exe = Environment.ProcessPath!;
        int threads = Math.Min(4, Math.Max(2, Environment.ProcessorCount / 2));
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "--tts", VoiceStore.RuntimeDir, m.Kind, VoiceStore.PathOf(m), threads.ToString() }) psi.ArgumentList.Add(a);
        psi.StandardInputEncoding = new UTF8Encoding(false);
        process = Process.Start(psi) ?? throw new LingveilException("Couldn't start the voice");
        process.ErrorDataReceived += (_, e) => { };
        process.BeginErrorReadLine();
        Job.Add(process);
    }

    /// Speaks `text` into a WAV file's bytes.
    public async Task<byte[]> Wav(string text, int speaker, double speed, string language, CancellationToken ct)
    {
        var line = text.Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');
        await one.WaitAsync(ct);
        try
        {
            return await Task.Run(() =>
            {
                try
                {
                    process.StandardInput.Write($"{speaker}\t{speed.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture)}\t{language}\t{line}\n");
                    process.StandardInput.Flush();
                    var o = process.StandardOutput.BaseStream;
                    var head = ReadExactly(o, 8) ?? throw new LingveilException("The voice stopped");
                    int rate = BitConverter.ToInt32(head, 0), count = BitConverter.ToInt32(head, 4);
                    if (count <= 0) throw new LingveilException("The voice couldn't read this");
                    var pcm = ReadExactly(o, count * 4) ?? throw new LingveilException("The voice stopped");
                    return Audio.Wav(MemoryMarshal.Cast<byte, float>(pcm).ToArray(), rate);
                }
                catch { try { process.Kill(); } catch { } throw; }
            }, CancellationToken.None);
        }
        finally { one.Release(); }
    }

    static byte[]? ReadExactly(Stream s, int n)
    {
        var buf = new byte[n];
        int got = 0;
        while (got < n) { int r = s.Read(buf, got, n - got); if (r <= 0) return null; got += r; }
        return buf;
    }
}

public static class Audio
{
    /// 32-bit float samples into a 16-bit PCM WAV.
    public static byte[] Wav(float[] samples, int rate)
    {
        int n = samples.Length;
        using var ms = new MemoryStream(44 + n * 2);
        using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8); w.Write(36 + n * 2); w.Write("WAVEfmt "u8);
        w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(n * 2);
        foreach (var f in samples) w.Write((short)(Math.Clamp(f, -1, 1) * 32767));
        w.Flush();
        return ms.ToArray();
    }
}

/// The helper itself: `Lingveil.exe --tts <runtime dir> <kind> <model dir> <threads>`, kind is
/// vits | kokoro | kitten | supertonic. Stdin, one request per line:
/// `<speaker>\t<speed>\t<language>\t<text>\n`. Stdout per request: int32 sample rate, int32
/// sample count (-1 = error), then float32 samples. Same protocol as the Mac's lingveil-tts.
public static unsafe class TtsHost
{
    [StructLayout(LayoutKind.Sequential)] struct Vits { public IntPtr model, lexicon, tokens, data_dir; public float noise_scale, noise_scale_w, length_scale; public IntPtr dict_dir; }
    [StructLayout(LayoutKind.Sequential)] struct Matcha { public IntPtr acoustic_model, vocoder, lexicon, tokens, data_dir; public float noise_scale, length_scale; public IntPtr dict_dir; }
    [StructLayout(LayoutKind.Sequential)] struct Kokoro { public IntPtr model, voices, tokens, data_dir; public float length_scale; public IntPtr dict_dir, lexicon, lang; }
    [StructLayout(LayoutKind.Sequential)] struct Kitten { public IntPtr model, voices, tokens, data_dir; public float length_scale; }
    [StructLayout(LayoutKind.Sequential)] struct Zipvoice { public IntPtr tokens, encoder, decoder, vocoder, data_dir, lexicon; public float feat_scale, t_shift, target_rms, guidance_scale; }
    [StructLayout(LayoutKind.Sequential)] struct Pocket { public IntPtr lm_flow, lm_main, encoder, decoder, text_conditioner, vocab_json, token_scores_json; public int cache; }
    [StructLayout(LayoutKind.Sequential)] struct Supertonic { public IntPtr duration_predictor, text_encoder, vector_estimator, vocoder, tts_json, unicode_indexer, voice_style; }
    [StructLayout(LayoutKind.Sequential)]
    struct ModelConfig { public Vits vits; public int num_threads, debug; public IntPtr provider; public Matcha matcha; public Kokoro kokoro; public Kitten kitten; public Zipvoice zipvoice; public Pocket pocket; public Supertonic supertonic; }
    [StructLayout(LayoutKind.Sequential)] struct TtsConfig { public ModelConfig model; public IntPtr rule_fsts; public int max_num_sentences; public IntPtr rule_fars; public float silence_scale; }
    [StructLayout(LayoutKind.Sequential)] struct GeneratedAudio { public float* samples; public int n, sample_rate; }
    [StructLayout(LayoutKind.Sequential)]
    struct GenerationConfig { public float silence_scale, speed; public int sid; public IntPtr reference_audio; public int reference_audio_len, reference_sample_rate; public IntPtr reference_text; public int num_steps; public IntPtr extra; }

    [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern bool SetDllDirectory(string path);

    static IntPtr Str(string s) => Marshal.StringToCoTaskMemUTF8(s);
    static string? FindFile(string dir, string suffix) => Directory.Exists(dir) ? Directory.GetFiles(dir).FirstOrDefault(f => f.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) : null;

    public static int Run(string runtime, string kind, string dir, int threads)
    {
        SetDllDirectory(runtime);
        var lib = NativeLibrary.Load(Path.Combine(runtime, "sherpa-onnx-c-api.dll"));
        var create = (delegate* unmanaged[Cdecl]<TtsConfig*, IntPtr>)NativeLibrary.GetExport(lib, "SherpaOnnxCreateOfflineTts");
        var destroy = (delegate* unmanaged[Cdecl]<IntPtr, void>)NativeLibrary.GetExport(lib, "SherpaOnnxDestroyOfflineTts");
        var rate = (delegate* unmanaged[Cdecl]<IntPtr, int>)NativeLibrary.GetExport(lib, "SherpaOnnxOfflineTtsSampleRate");
        var generate = (delegate* unmanaged[Cdecl]<IntPtr, byte*, GenerationConfig*, IntPtr, IntPtr, GeneratedAudio*>)NativeLibrary.GetExport(lib, "SherpaOnnxOfflineTtsGenerateWithConfig");
        var freeAudio = (delegate* unmanaged[Cdecl]<GeneratedAudio*, void>)NativeLibrary.GetExport(lib, "SherpaOnnxDestroyOfflineTtsGeneratedAudio");

        TtsConfig c = default;
        c.model.num_threads = threads > 0 ? threads : 2;
        c.model.provider = Str("cpu");
        c.max_num_sentences = 1;
        string P(string name) => Path.Combine(dir, name);
        var espeak = Str(P("espeak-ng-data"));
        switch (kind)
        {
            case "vits":
                c.model.vits.model = Str(FindFile(dir, ".onnx") ?? P("model.onnx"));
                c.model.vits.tokens = Str(P("tokens.txt"));
                c.model.vits.data_dir = espeak;
                c.model.vits.noise_scale = 0.667f; c.model.vits.noise_scale_w = 0.8f; c.model.vits.length_scale = 1;
                break;
            case "kokoro":
                c.model.kokoro.model = Str(File.Exists(P("model.int8.onnx")) ? P("model.int8.onnx") : P("model.onnx"));
                c.model.kokoro.voices = Str(P("voices.bin"));
                c.model.kokoro.tokens = Str(P("tokens.txt"));
                c.model.kokoro.data_dir = espeak;
                c.model.kokoro.length_scale = 1;
                if (Directory.Exists(P("dict"))) c.model.kokoro.dict_dir = Str(P("dict"));
                if (File.Exists(P("lexicon-us-en.txt")) && File.Exists(P("lexicon-zh.txt"))) c.model.kokoro.lexicon = Str(P("lexicon-us-en.txt") + "," + P("lexicon-zh.txt"));
                break;
            case "kitten":
                c.model.kitten.model = Str(File.Exists(P("model.int8.onnx")) ? P("model.int8.onnx") : FindFile(dir, ".onnx") ?? P("model.onnx"));
                c.model.kitten.voices = Str(P("voices.bin"));
                c.model.kitten.tokens = Str(P("tokens.txt"));
                c.model.kitten.data_dir = espeak;
                c.model.kitten.length_scale = 1;
                break;
            case "supertonic":
                c.model.supertonic.duration_predictor = Str(P("duration_predictor.int8.onnx"));
                c.model.supertonic.text_encoder = Str(P("text_encoder.int8.onnx"));
                c.model.supertonic.vector_estimator = Str(P("vector_estimator.int8.onnx"));
                c.model.supertonic.vocoder = Str(P("vocoder.int8.onnx"));
                c.model.supertonic.tts_json = Str(P("tts.json"));
                c.model.supertonic.unicode_indexer = Str(P("unicode_indexer.bin"));
                c.model.supertonic.voice_style = Str(P("voice.bin"));
                break;
            default: Console.Error.WriteLine("unknown kind " + kind); return 2;
        }
        var tts = create(&c);
        if (tts == IntPtr.Zero) { Console.Error.WriteLine("could not load the model"); return 4; }
        int sr = rate(tts);
        string kokoroLang = "";
        var stdin = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
        var stdout = Console.OpenStandardOutput();
        while (true)
        {
            var read = stdin.ReadLineAsync();
            if (!read.Wait(TimeSpan.FromMinutes(2))) break;   // idle: give the memory back
            var line = read.Result;
            if (line == null) break;
            var parts = line.Split('\t', 4);
            int count = -1;
            GeneratedAudio* a = null;
            if (parts.Length == 4)
            {
                // Kokoro picks its pronunciation language when it loads: reload when it changes.
                if (kind == "kokoro" && parts[2] != kokoroLang)
                {
                    kokoroLang = parts[2];
                    c.model.kokoro.lang = Str(kokoroLang);
                    destroy(tts);
                    tts = create(&c);
                    if (tts == IntPtr.Zero) { Console.Error.WriteLine("could not load the model"); return 4; }
                }
                GenerationConfig g = default;
                g.sid = int.TryParse(parts[0], out var sid) ? sid : 0;
                g.speed = float.TryParse(parts[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var sp) ? sp : 1;
                g.silence_scale = 0.2f;
                g.extra = Str($"{{\"lang\": \"{parts[2]}\"}}");
                var text = Encoding.UTF8.GetBytes(parts[3] + "\0");
                fixed (byte* t = text) a = generate(tts, t, &g, IntPtr.Zero, IntPtr.Zero);
                Marshal.FreeCoTaskMem(g.extra);
                if (a != null && a->n > 0) count = a->n;
            }
            try
            {
                stdout.Write(BitConverter.GetBytes(sr));
                stdout.Write(BitConverter.GetBytes(count));
                if (count > 0) stdout.Write(new ReadOnlySpan<byte>(a->samples, count * 4));
                stdout.Flush();
            }
            catch { break; }
            finally { if (a != null) freeAudio(a); }
        }
        return 0;
    }
}
