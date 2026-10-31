using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Lingveil.Core;

public interface ITranslator
{
    /// Returns one translation per input, in order. A text already in the target language
    /// may come back unchanged.
    Task<string[]> Translate(IReadOnlyList<string> texts, Language target, CancellationToken ct = default);
}

/// Picks the engine from settings, falls back to the local model when the network engine
/// fails, and caches results so repeated text (live mode, re-opened windows) is instant.
public static class Translation
{
    static readonly Dictionary<string, string> cache = [];
    static readonly object gate = new();

    public static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        MaxConnectionsPerServer = 6,
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(90),
        AutomaticDecompression = DecompressionMethods.All,
    }) { Timeout = TimeSpan.FromSeconds(6) };

    static string Key(Language t, string s) => t.Code + "\u0001" + s;

    public static async Task<string[]> Translate(IReadOnlyList<string> texts, Language target, CancellationToken ct = default)
    {
        var results = new string?[texts.Count];
        var missing = new List<string>();
        lock (gate)
            for (int i = 0; i < texts.Count; i++)
                if (cache.TryGetValue(Key(target, texts[i]), out var hit)) results[i] = hit;
                else if (!missing.Contains(texts[i])) missing.Add(texts[i]);
        if (missing.Count > 0)
        {
            var fresh = await Run(missing, target, ct);
            lock (gate)
            {
                if (cache.Count > 20_000) cache.Clear();
                for (int i = 0; i < missing.Count; i++) cache[Key(target, missing[i])] = fresh[i];
                for (int i = 0; i < texts.Count; i++) results[i] ??= cache.GetValueOrDefault(Key(target, texts[i]));
            }
        }
        return results.Select((r, i) => r ?? texts[i]).ToArray();
    }

    public static string? Cached(string text, Language target) { lock (gate) return cache.GetValueOrDefault(Key(target, text)); }

    static async Task<string[]> Run(IReadOnlyList<string> texts, Language target, CancellationToken ct)
    {
        var s = Settings.Current;
        switch (s.EffectiveEngine)
        {
            case EngineKind.Auto:
                try { return await new GoogleWeb().Translate(texts, target, ct); }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch { return await Offline(texts, target, ct); }
            case EngineKind.Google: return await new GoogleWeb().Translate(texts, target, ct);
            case EngineKind.Local: return await Offline(texts, target, ct);
            case EngineKind.GoogleCloud: return await new GoogleCloud(s.GoogleCloudKey).Translate(texts, target, ct);
            case EngineKind.Deepl: return await new DeepL(s.DeeplKey).Translate(texts, target, ct);
            default: return await new Ollama(s.OllamaUrl, s.OllamaModel).Translate(texts, target, ct);
        }
    }

    /// The chosen local model when it is downloaded and can do this language. Windows has no
    /// built-in offline translator, so without one this says to download a model.
    static Task<string[]> Offline(IReadOnlyList<string> texts, Language target, CancellationToken ct)
    {
        var m = LocalModel.Named(Settings.Current.EffectiveLocalModel);
        if (m == null || !ModelStore.IsInstalled(m))
            throw new LingveilException(Settings.Current.EffectiveEngine == EngineKind.Local
                ? $"Download {m?.Name ?? "a model"} in Settings → Models first"
                : "You're offline. Download a model in Settings → Models to translate without internet");
        if (!m.Supports(target)) throw new LingveilException($"{m.Name} can't translate into {target.Name}");
        return new LocalTranslator(m).Translate(texts, target, ct);
    }

    /// Splits work into request-sized chunks and runs them concurrently, keeping order.
    public static async Task<string[]> Chunked(IReadOnlyList<string> texts, int maxItems, int maxChars, Func<List<string>, Task<string[]>> body)
    {
        var chunks = new List<List<string>> { new() };
        int chars = 0;
        foreach (var t in texts)
        {
            if (chunks[^1].Count >= maxItems || (chars + t.Length > maxChars && chunks[^1].Count > 0)) { chunks.Add([]); chars = 0; }
            chunks[^1].Add(t); chars += t.Length;
        }
        var parts = await Task.WhenAll(chunks.Select(body));
        return parts.SelectMany(p => p).ToArray();
    }

    /// Opens (or keeps) the HTTPS connection while the screen is still being captured and
    /// read, so the real request doesn't pay for DNS and TLS.
    public static void Preconnect()
    {
        if (Settings.Current.EffectiveEngine is not (EngineKind.Auto or EngineKind.Google)) return;
        _ = Task.Run(async () =>
        {
            try { using var r = await Http.GetAsync("https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=en&q=ok"); }
            catch { }
        });
    }
}

/// The endpoint Chrome's translate extension uses: batched, per-item language detection,
/// no account or key.
public sealed class GoogleWeb : ITranslator
{
    public Task<string[]> Translate(IReadOnlyList<string> texts, Language target, CancellationToken ct = default) =>
        Translation.Chunked(texts, 30, 1500, async chunk =>
        {
            var url = $"https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl={Uri.EscapeDataString(target.Code)}";
            var body = string.Join("&", chunk.Select(t => "q=" + Uri.EscapeDataString(t)));
            using var content = new StringContent(body, Encoding.UTF8, "application/x-www-form-urlencoded");
            using var resp = await Translation.Http.PostAsync(url, content, ct);
            if (resp.StatusCode != HttpStatusCode.OK) throw new LingveilException("Google Translate is not reachable right now");
            var json = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct)) as JsonArray
                ?? throw new LingveilException("Unexpected reply from Google Translate");
            // Rows are [translation, detected language]; a single string comes back flattened.
            var rows = chunk.Count == 1 && json.Count > 0 && json[0] is JsonValue ? new JsonArray(json.DeepClone()) : json;
            if (rows.Count != chunk.Count) throw new LingveilException("Unexpected reply from Google Translate");
            var tl = target.Code.ToLowerInvariant();
            return chunk.Select((original, i) =>
            {
                if (rows[i] is JsonValue v) return v.GetValue<string>();
                if (rows[i] is not JsonArray a || a.Count == 0 || a[0] is not JsonValue tv) return original;
                // Already in the target language: keep the original rather than Google's echo,
                // which would "correct" OCR slips on screen.
                var src = (a[^1] as JsonValue)?.GetValue<string>()?.ToLowerInvariant();
                if (a.Count > 1 && src != null && (src == tl || tl.StartsWith(src + "-"))) return original;
                return tv.GetValue<string>();
            }).ToArray();
        });
}

/// Google Cloud Translation v2 with the user's key (500k characters/month free).
public sealed class GoogleCloud(string key) : ITranslator
{
    public Task<string[]> Translate(IReadOnlyList<string> texts, Language target, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(key)) throw new LingveilException("Add a Google Cloud API key in Settings → Engines");
        return Translation.Chunked(texts, 128, 25_000, async chunk =>
        {
            using var resp = await Translation.Http.PostAsJsonAsync($"https://translation.googleapis.com/language/translate/v2?key={Uri.EscapeDataString(key)}",
                new { q = chunk, target = target.Code, format = "text" }, ct);
            var obj = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct));
            var list = obj?["data"]?["translations"] as JsonArray
                ?? throw new LingveilException(obj?["error"]?["message"]?.GetValue<string>() ?? "Google Cloud request failed");
            return list.Select(t => t?["translatedText"]?.GetValue<string>() ?? "").ToArray();
        });
    }
}

/// DeepL with the user's key; keys ending in ":fx" use the free host.
public sealed class DeepL(string key) : ITranslator
{
    public Task<string[]> Translate(IReadOnlyList<string> texts, Language target, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(key)) throw new LingveilException("Add a DeepL API key in Settings → Engines");
        var host = key.EndsWith(":fx") ? "api-free.deepl.com" : "api.deepl.com";
        var lang = target.Code switch { "en" => "EN-US", "pt" => "PT-BR", "zh-CN" => "ZH-HANS", "zh-TW" => "ZH-HANT", "iw" => "HE", var c => c.ToUpperInvariant() };
        return Translation.Chunked(texts, 50, 30_000, async chunk =>
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, $"https://{host}/v2/translate") { Content = JsonContent.Create(new { text = chunk, target_lang = lang }) };
            req.Headers.TryAddWithoutValidation("Authorization", "DeepL-Auth-Key " + key);
            using var resp = await Translation.Http.SendAsync(req, ct);
            var list = resp.IsSuccessStatusCode ? JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct))?["translations"] as JsonArray : null;
            if (list == null) throw new LingveilException("DeepL request failed (check the key)");
            return list.Select(t => t?["text"]?.GetValue<string>() ?? "").ToArray();
        });
    }
}

/// Ollama or another local server speaking its /api/chat.
public sealed class Ollama(string baseUrl, string model) : ITranslator
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(60) };

    public Task<string[]> Translate(IReadOnlyList<string> texts, Language target, CancellationToken ct = default) =>
        Translation.Chunked(texts, 40, 3000, async chunk =>
        {
            var prompt = $"Translate every string in this JSON array into {target.Name}. Keep names, numbers, URLs and emoji as they are. " +
                         $"Translate UI labels the way a native app in {target.Name} would label them. " +
                         $"Reply with only a JSON object {{\"t\": [...]}} holding exactly {chunk.Count} strings in the same order.\n" +
                         JsonSerializer.Serialize(chunk);
            using var resp = await http.PostAsJsonAsync(baseUrl.TrimEnd('/') + "/api/chat", new
            {
                model, stream = false, format = "json", think = false,
                options = new { temperature = 0 },
                messages = new[] { new { role = "user", content = prompt } },
            }, ct);
            try
            {
                var content = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct))?["message"]?["content"]?.GetValue<string>();
                var list = (JsonNode.Parse(content!)?["t"] as JsonArray)?.Select(n => n?.GetValue<string>() ?? "").ToArray();
                if (list?.Length == chunk.Count) return list;
            }
            catch { }
            throw new LingveilException($"Ollama did not return a usable translation (is {model} pulled?)");
        });
}
