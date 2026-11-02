using System.Text.Json;
using System.Text.Json.Serialization;

namespace Lingveil.Core;

public enum EngineKind { Auto, Google, Local, GoogleCloud, Deepl, Ollama }
public enum OverlayStyle { Seamless, Card }

/// Every user setting, in %APPDATA%\Lingveil\settings.json. LINGVEIL_TARGET, LINGVEIL_ENGINE
/// and LINGVEIL_LOCAL_MODEL override for a run (bench, tests) and are never written back.
public sealed class Settings
{
    public string? Target { get; set; }
    public EngineKind Engine { get; set; } = EngineKind.Auto;
    public OverlayStyle Style { get; set; } = OverlayStyle.Seamless;
    public bool UseAccessibility { get; set; } = true;
    public bool HoverWithAlt { get; set; }
    public string GoogleCloudKey { get; set; } = "";
    public string DeeplKey { get; set; } = "";
    public string LocalModel { get; set; } = "index-translate-2b";
    public string OllamaUrl { get; set; } = "http://localhost:11434";
    public string OllamaModel { get; set; } = "qwen3:4b";
    public Dictionary<string, string> Shortcuts { get; set; } = [];
    /// Languages the user reads on screen; their OCR packs are the ones that matter.
    public List<string> ReadLanguages { get; set; } = [];
    public bool WebParagraphs { get; set; } = true;
    /// Translate Screen follows the front window while it scrolls and is used (SPEC §2.12b).
    public bool FollowScroll { get; set; } = true;

    /// Read aloud: "system", a plugin's name from engines.json, or "model:<id>".
    public string VoiceEngine { get; set; } = "system";
    public double SpeechSpeed { get; set; } = 1.0;
    /// Chosen voice per language ("hi") or per plugin and language ("Google|hi").
    public Dictionary<string, string> VoiceIds { get; set; } = [];

    public bool TutorialShown { get; set; }
    public List<string> TipsShown { get; set; } = [];

    // Ko-fi reminder bookkeeping (SPEC §2.16).
    public int Uses { get; set; }
    public int UseDays { get; set; }
    public long LastUseDay { get; set; }
    public DateTime? FirstUse { get; set; }
    public DateTime? SupportQuietUntil { get; set; }
    public string? LastVersion { get; set; }

    public static string Folder { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lingveil");
    static string FilePath => Path.Combine(Folder, "settings.json");
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } };

    public static Settings Current { get; private set; } = Load();

    static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Json) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Folder);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json));
    }

    public Language TargetLanguage =>
        Environment.GetEnvironmentVariable("LINGVEIL_TARGET") is { } t ? Shared.Language(t)
        : Target is { } c ? Shared.Language(c) : Shared.SystemDefault;

    public EngineKind EffectiveEngine =>
        Enum.TryParse<EngineKind>(Environment.GetEnvironmentVariable("LINGVEIL_ENGINE"), true, out var e) ? e : Engine;

    public string EffectiveLocalModel => Environment.GetEnvironmentVariable("LINGVEIL_LOCAL_MODEL") ?? LocalModel;

    // Automatic is Google until it fails, so it batches like an online engine.
    public bool IsNetworkEngine => EffectiveEngine is EngineKind.Auto or EngineKind.Google or EngineKind.GoogleCloud or EngineKind.Deepl;
}
