using System.Text.Json;
using System.Text.Json.Nodes;

namespace Lingveil.Core;

public record Language(string Code, string Name, string AppleId, string ChineseName);

/// Reads shared/models.json and shared/languages.json, which the Mac app reads too.
/// They are copied next to the exe at build time; running from the source tree falls
/// back to the repo's shared/ folder.
public static class Shared
{
    public static string Find(string file)
    {
        var next = Path.Combine(AppContext.BaseDirectory, "shared", file);
        if (File.Exists(next)) return next;
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent)
        {
            var p = Path.Combine(d.FullName, "shared", file);
            if (File.Exists(p)) return p;
        }
        throw new FileNotFoundException("shared/" + file + " not found");
    }

    public static readonly IReadOnlyList<Language> Languages = LoadLanguages();
    public static readonly JsonObject Models = JsonNode.Parse(File.ReadAllText(Find("models.json")))!.AsObject();

    static List<Language> LoadLanguages()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(Find("languages.json")));
        return doc.RootElement.GetProperty("languages").EnumerateArray().Select(l => new Language(
            l.GetProperty("code").GetString()!, l.GetProperty("name").GetString()!,
            l.TryGetProperty("appleId", out var a) ? a.GetString()! : l.GetProperty("code").GetString()!,
            l.TryGetProperty("chineseName", out var c) ? c.GetString()! : l.GetProperty("name").GetString()!)).ToList();
    }

    public static Language Language(string code) =>
        Languages.FirstOrDefault(l => l.Code == code) ?? new Language(code, code, code, code);

    /// The system UI language mapped onto the list (zh-Hant/TW/HK → zh-TW, he → iw).
    public static Language SystemDefault
    {
        get
        {
            var c = System.Globalization.CultureInfo.CurrentUICulture;
            var id = c.Name;
            if (id.StartsWith("zh")) return Language(id.Contains("Hant") || id.Contains("TW") || id.Contains("HK") ? "zh-TW" : "zh-CN");
            var b = c.TwoLetterISOLanguageName;
            if (b == "he") b = "iw";
            if (b == "no" || b == "nn") b = "nb";
            if (b == "fil") b = "tl";
            return Languages.FirstOrDefault(l => l.Code == b || l.AppleId == b) ?? Language("en");
        }
    }
}
