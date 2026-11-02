using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;
using Windows.Storage.Streams;
using Lingveil.Core;

namespace Lingveil.App;

/// One piece of text to speak, with where it is on screen (physical pixels, to outline
/// while it's read) and its language (to pick a voice that speaks it). shared/SPEC.md §2.14.
public sealed record Segment(string Text, Int32Rect? Rect, string? Language)
{
    public string Lang => Language ?? Detect.Language(Text);
}

/// Something that can speak a segment and returns when it has finished.
public interface IVoiceEngine
{
    void Prepare(Segment s);   // look-ahead: make the next segment's audio while this one plays
    Task Speak(Segment s, CancellationToken ct);
    void Stop();
}

/// Reads segments one after another, outlining each on screen. Esc or the same shortcut stops.
public sealed class Narrator
{
    public static readonly Narrator Shared = new();
    CancellationTokenSource? cts;
    IVoiceEngine? engine;
    int? stopKey;
    public bool IsSpeaking { get; private set; }
    /// Tests: what was said, one line per segment.
    public List<string> DebugSaid { get; } = [];

    public void Read(IReadOnlyList<Segment> segments, Action<int?> highlight)
    {
        Stop();
        var segs = segments.Where(s => !string.IsNullOrWhiteSpace(s.Text)).ToList();
        if (segs.Count == 0) return;
        var e = engine = Voices.Engine();
        var c = cts = new CancellationTokenSource();
        IsSpeaking = true;
        DebugSaid.Clear();
        Tray.Busy(true);
        stopKey = HotKeys.Shared.Register(new Shortcut(0, Native.VK_ESCAPE), Stop);
        Hud.Tip("reading");
        var ui = Application.Current.Dispatcher;
        _ = Task.Run(async () =>
        {
            try
            {
                for (int i = 0; i < segs.Count && !c.IsCancellationRequested; i++)
                {
                    var s = segs[i];
                    Debug.Log($"say {i} [{s.Lang}] {(s.Text.Length > 40 ? s.Text[..40] : s.Text)}");
                    lock (DebugSaid) DebugSaid.Add($"[{s.Lang}] {s.Text}");
                    int k = i;
                    await ui.InvokeAsync(() => { if (cts == c) highlight(k); });
                    if (i + 1 < segs.Count) e.Prepare(segs[i + 1]);
                    await e.Speak(s, c.Token);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Debug.Log("speak error " + ex);
                if (!c.IsCancellationRequested) await ui.InvokeAsync(() => Hud.Flash("Couldn't read aloud: " + ex.Message));
            }
            await ui.InvokeAsync(() =>
            {
                highlight(null);
                if (cts == c) { Finish(); Hud.Used(); Hud.MaybeAsk(); }
            });
        });
    }

    public void Stop()
    {
        cts?.Cancel(); cts = null;
        engine?.Stop(); engine = null;
        Finish();
    }

    void Finish()
    {
        HotKeys.Shared.Unregister(stopKey); stopKey = null;
        if (IsSpeaking) Tray.Busy(false);
        IsSpeaking = false;
        Highlighter.Hide();
    }
}

/// Plays WAV bytes and returns when they have finished (or are stopped).
public static class Player
{
    public static async Task Play(byte[] wav, double rate, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(wav.AsBuffer());
        stream.Seek(0);
        var p = new Windows.Media.Playback.MediaPlayer { AutoPlay = false };
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        p.MediaEnded += (_, _) => done.TrySetResult();
        p.MediaFailed += (_, e) => done.TrySetException(new LingveilException(e.ErrorMessage));
        p.MediaOpened += (_, _) => { if (Math.Abs(rate - 1) > 0.01) p.PlaybackSession.PlaybackRate = rate; p.Play(); };
        p.Source = MediaSource.CreateFromStream(stream, "audio/wav");
        try
        {
            using (ct.Register(() => done.TrySetCanceled()))
                await done.Task;
        }
        finally { p.Pause(); p.Dispose(); }
    }
}

/// The voices built into Windows (Windows.Media.SpeechSynthesis, the OneCore voices).
public sealed class SystemVoices : IVoiceEngine
{
    public void Prepare(Segment s) { }

    public async Task Speak(Segment s, CancellationToken ct)
    {
        var voice = Voices.SystemVoice(s.Lang);
        using var synth = new SpeechSynthesizer();
        if (voice != null) synth.Voice = voice;
        synth.Options.SpeakingRate = Math.Clamp(Settings.Current.SpeechSpeed, 0.5, 6);
        byte[] wav;
        using (var stream = await synth.SynthesizeTextToStreamAsync(s.Text))
        {
            wav = new byte[stream.Size];
            await stream.ReadAsync(wav.AsBuffer(), (uint)stream.Size, InputStreamOptions.None);
        }
        await Player.Play(wav, 1, ct);
        await Task.Delay(80, ct);
    }

    public void Stop() { }
}

/// A voice plugin from engines.json (same format as Earmark): an HTTP endpoint that returns
/// WAV for {text, voice, rate}, or a command that writes a WAV file.
public sealed class PluginVoices(PluginConfig config) : IVoiceEngine
{
    readonly Dictionary<string, Task<byte[]>> cache = [];
    readonly SystemVoices fallback = new();
    readonly CancellationTokenSource stop = new();

    Task<byte[]> Audio(Segment s)
    {
        lock (cache)
        {
            if (cache.TryGetValue(s.Text, out var t)) return t;
            var voice = Voices.PluginVoice(config, s.Lang);
            double speed = config.Speed == "player" ? 1 : Settings.Current.SpeechSpeed;
            return cache[s.Text] = Plugins.Synthesize(config, voice, s.Text, speed, stop.Token);
        }
    }

    /// Lines in a language the plugin has no voice for are read by the Windows voice.
    bool Covers(Segment s) => Voices.PluginVoice(config, s.Lang) != null || Plugins.Voices(config).Count == 0;

    public void Prepare(Segment s) { if (Covers(s)) _ = Audio(s); }

    public async Task Speak(Segment s, CancellationToken ct)
    {
        if (!Covers(s)) { await fallback.Speak(s, ct); return; }
        var data = await Audio(s).WaitAsync(ct);
        lock (cache) cache.Remove(s.Text);
        await Player.Play(data, config.Speed == "player" ? Math.Min(2, Settings.Current.SpeechSpeed) : 1, ct);
    }

    public void Stop() => stop.Cancel();
}

/// Reads with a downloaded narration model. Paragraphs are cut into sentences so the first
/// one plays while the next is being made, and the next segment is made ahead of time.
public sealed partial class ModelVoices(VoiceModel model) : IVoiceEngine
{
    readonly Dictionary<string, Task<byte[]>> cache = [];
    readonly SystemVoices fallback = new();
    readonly CancellationTokenSource stop = new();

    [GeneratedRegex(@"(?<=[.!?。！？।])\s+|(?<=[。！？])")] private static partial Regex SentenceEnd();

    static List<string> Sentences(string text)
    {
        var parts = SentenceEnd().Split(text).Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
        return parts.Count == 0 ? [text] : parts;
    }

    Task<byte[]> Audio(string text, VoiceModel m, string lang)
    {
        lock (cache)
        {
            var key = m.Id + "|" + text;
            if (cache.TryGetValue(key, out var t)) return t;
            double speed = Settings.Current.SpeechSpeed;
            return cache[key] = Task.Run(() => TtsHelper.For(m).Wav(text, m.Speaker(lang), speed, VoiceModel.Base(lang), stop.Token));
        }
    }

    public void Prepare(Segment s)
    {
        if (VoiceStore.ModelFor(s.Lang, model) is { } m) _ = Audio(Sentences(s.Text)[0], m, s.Lang);
    }

    public async Task Speak(Segment s, CancellationToken ct)
    {
        if (VoiceStore.ModelFor(s.Lang, model) is not { } m) { await fallback.Speak(s, ct); return; }
        var parts = Sentences(s.Text);
        for (int i = 0; i < parts.Count; i++)
        {
            var data = await Audio(parts[i], m, s.Lang).WaitAsync(ct);
            lock (cache) cache.Remove(m.Id + "|" + parts[i]);
            if (i + 1 < parts.Count) _ = Audio(parts[i + 1], m, s.Lang);
            await Player.Play(data, 1, ct);
        }
    }

    public void Stop() => stop.Cancel();
}

/// Which engine and voice reads what.
public static class Voices
{
    /// The engine the user picked: "system", a plugin's name, or "model:<id>".
    public static IVoiceEngine Engine()
    {
        var e = Settings.Current.VoiceEngine;
        if (e.StartsWith("model:") && VoiceStore.RuntimeInstalled && VoiceStore.Installed.FirstOrDefault(m => "model:" + m.Id == e) is { } m) return new ModelVoices(m);
        if (e != "system" && Plugins.Load().FirstOrDefault(p => p.Name == e) is { } p) return new PluginVoices(p);
        return new SystemVoices();
    }

    /// Windows' own codes for the few languages whose list code differs.
    public static string Normalize(string lang) => lang switch { "iw" => "he", "tl" => "fil", "zh-CN" => "zh-CN", _ => lang };

    public static IReadOnlyList<VoiceInformation> SystemVoices(string lang)
    {
        var l = Normalize(lang).ToLowerInvariant();
        var b = VoiceModel.Base(l);
        try
        {
            return SpeechSynthesizer.AllVoices
                .Where(v => v.Language.ToLowerInvariant() == l || VoiceModel.Base(v.Language) == b)
                .OrderBy(v => v.Language.ToLowerInvariant() == l ? 0 : 1).ThenBy(v => v.DisplayName).ToList();
        }
        catch { return []; }
    }

    /// The voice chosen for a language in Settings, else the best installed one for it
    /// (exact region first, then the user's region).
    public static VoiceInformation? SystemVoice(string lang)
    {
        var b = VoiceModel.Base(Normalize(lang));
        var all = SystemVoices(lang);
        if (Settings.Current.VoiceIds.TryGetValue(b, out var id) && all.FirstOrDefault(v => v.Id == id) is { } chosen) return chosen;
        var region = System.Globalization.RegionInfo.CurrentRegion.TwoLetterISORegionName.ToLowerInvariant();
        return all.OrderBy(v => v.Language.ToLowerInvariant().EndsWith("-" + region) ? 0 : 1).FirstOrDefault();
    }

    /// With Windows voices, drops segments in languages that have no installed voice (they'd
    /// come out garbled in another language's voice) and says how to add one.
    public static List<Segment> Speakable(List<Segment> segs)
    {
        if (Settings.Current.VoiceEngine != "system") return segs;
        var missing = new HashSet<string>();
        var outp = segs.Where(s =>
        {
            bool ok = SystemVoices(s.Lang).Count > 0;
            if (!ok) missing.Add(VoiceModel.Base(s.Lang));
            return ok;
        }).ToList();
        if (missing.FirstOrDefault() is { } lang)
            Hud.Flash($"No {Shared.Language(lang).Name} voice installed. Add one in Windows Settings → Time & language → Speech.");
        return outp;
    }

    public static string? PluginVoice(PluginConfig c, string language)
    {
        var b = VoiceModel.Base(language);
        if (Settings.Current.VoiceIds.TryGetValue($"{c.Name}|{b}", out var id)) return id;
        var voices = Plugins.Voices(c);
        if (b == "en" && voices.FirstOrDefault(v => v.Id.EndsWith("/sfg")) is { } sfg) return sfg.Id;
        return voices.FirstOrDefault(v => v.Language.ToLowerInvariant().StartsWith(b))?.Id;
    }
}

public sealed class PluginConfig
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("url")] public string? Url { get; set; }
    [JsonPropertyName("command")] public List<string>? Command { get; set; }
    [JsonPropertyName("voices")] public string? VoicesUrl { get; set; }
    [JsonPropertyName("speed")] public string? Speed { get; set; }   // "engine": the plugin gets the speed; "player": playback is sped up
    [JsonPropertyName("enabled")] public bool? Enabled { get; set; }
    [JsonPropertyName("start")] public List<string>? Start { get; set; }   // started once if the server can't be reached
}

public sealed record PluginVoice(
    [property: JsonPropertyName("id")] string Id, [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("language")] string Language, [property: JsonPropertyName("gender")] string? Gender);

/// Voice plugins listed in %APPDATA%\Lingveil\engines.json.
public static class Plugins
{
    public static string File => Path.Combine(Settings.Folder, "engines.json");
    static readonly Dictionary<string, List<PluginVoice>> voiceCache = [];
    static readonly HashSet<string> started = [];

    sealed class Root { [JsonPropertyName("engines")] public List<PluginConfig> Engines { get; set; } = []; }

    public static List<PluginConfig> Load()
    {
        try { return (JsonSerializer.Deserialize<Root>(System.IO.File.ReadAllText(File))?.Engines ?? []).Where(e => e.Enabled != false).ToList(); }
        catch { return []; }
    }

    public static List<PluginVoice> Voices(PluginConfig c)
    {
        lock (voiceCache) if (voiceCache.TryGetValue(c.Name, out var v)) return v;
        if (c.VoicesUrl == null) return [];
        List<PluginVoice> outp = [];
        try
        {
            using var cts = new CancellationTokenSource(3000);
            var json = Translation.Http.GetStringAsync(c.VoicesUrl, cts.Token).GetAwaiter().GetResult();
            outp = JsonSerializer.Deserialize<List<PluginVoice>>(json) ?? [];
        }
        catch { }
        if (outp.Count == 0 && StartIfNeeded(c)) return Voices(c);
        if (outp.Count > 0) lock (voiceCache) voiceCache[c.Name] = outp;
        return outp;
    }

    /// Runs the plugin's start command once (for example a background voice service).
    static bool StartIfNeeded(PluginConfig c)
    {
        if (c.Start is not { Count: > 0 } cmd) return false;
        lock (started) if (!started.Add(c.Name)) return false;
        try
        {
            var psi = new ProcessStartInfo(cmd[0]) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in cmd.Skip(1)) psi.ArgumentList.Add(a);
            Process.Start(psi)?.WaitForExit(15000);
            Thread.Sleep(1500);
        }
        catch { }
        return true;
    }

    public static async Task<byte[]> Synthesize(PluginConfig c, string? voice, string text, double speed, CancellationToken ct)
    {
        if (c.Url != null)
        {
            var body = new Dictionary<string, object> { ["text"] = text, ["rate"] = speed };
            if (voice != null) body["voice"] = voice;
            try
            {
                using var resp = await Translation.Http.PostAsync(c.Url, new StringContent(JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json"), ct);
                if (!resp.IsSuccessStatusCode) throw new LingveilException($"{c.Name} returned an error");
                return await resp.Content.ReadAsByteArrayAsync(ct);
            }
            catch (HttpRequestException)
            {
                if (StartIfNeeded(c)) return await Synthesize(c, voice, text, speed, ct);
                throw new LingveilException($"{c.Name} isn't running");
            }
        }
        if (c.Command is not { Count: > 0 } cmd) throw new LingveilException($"{c.Name} needs a url or a command");
        var outFile = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".wav");
        try
        {
            var psi = new ProcessStartInfo(cmd[0]) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true };
            foreach (var a in cmd.Skip(1))
                psi.ArgumentList.Add(a.Replace("{out}", outFile).Replace("{voice}", voice ?? "").Replace("{speed}", speed.ToString(System.Globalization.CultureInfo.InvariantCulture)));
            using var p = Process.Start(psi)!;
            await p.StandardInput.WriteAsync(text);
            p.StandardInput.Close();
            await p.WaitForExitAsync(ct);
            if (p.ExitCode != 0) throw new LingveilException($"{c.Name} exited with {p.ExitCode}");
            return await System.IO.File.ReadAllBytesAsync(outFile, ct);
        }
        finally { try { System.IO.File.Delete(outFile); } catch { } }
    }
}

/// A soft outline around the original text being read: click-through, topmost, with a 10%
/// accent tint.
public static class Highlighter
{
    static Window? window;

    public static void Show(Int32Rect r)
    {
        var accent = SystemColors.HighlightColor;
        var frame = new Int32Rect(r.X - 6, r.Y - 4, r.Width + 12, r.Height + 8);
        if (window == null)
        {
            var b = new System.Windows.Controls.Border
            {
                CornerRadius = new CornerRadius(5), BorderThickness = new Thickness(2),
                BorderBrush = new SolidColorBrush(Color.FromArgb(217, accent.R, accent.G, accent.B)),
                Background = new SolidColorBrush(Color.FromArgb(26, accent.R, accent.G, accent.B)),
            };
            var w = new Window
            {
                WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true,
                ShowInTaskbar = false, ShowActivated = false, ResizeMode = ResizeMode.NoResize, Content = b,
            };
            w.SourceInitialized += (_, _) =>
            {
                var h = new WindowInteropHelper(w).Handle;
                Native.MakeOverlay(h, clickThrough: true);
                Native.ExcludeFromCapture(h);
                Native.Place(h, frame);
            };
            w.Show();
            window = w;
        }
        Native.Place(new WindowInteropHelper(window).Handle, frame);
    }

    public static void Hide() { window?.Close(); window = null; }
}
