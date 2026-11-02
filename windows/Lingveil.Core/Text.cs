using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media;

namespace Lingveil.Core;

/// Measuring text in the system UI font, used to estimate OCR font sizes and split label rows.
public static class Measure
{
    public static readonly Typeface UiFont = new(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);

    public static double Width(string text, double size) =>
        new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, UiFont, size, Brushes.Black, 1.0)
            .WidthIncludingTrailingWhitespace;
}

public static partial class Filters
{
    [GeneratedRegex(@"^[^\s.][^\s]*\.[a-z][a-z0-9]{0,4}$")] private static partial Regex FileName();
    [GeneratedRegex(@"[_/\\]|[a-z][A-Z]|\(\)")] private static partial Regex CodeLike();

    /// File names, URLs, paths, emails, handles and code-ish tokens read the same in every
    /// language; translating them only mangles them.
    [GeneratedRegex(@"&&|\|\||\s\|\s|^\$\s|\s--?[a-zA-Z]|\b\w+=[^\s]|[{};]\s*$|<<|>>|::|->|=>")] private static partial Regex CodeLine();

    public static bool IsLiteral(string text)
    {
        var t = text.Trim();
        if (t.Contains("://") || t.StartsWith("www.") || t.StartsWith('/') || t.StartsWith("~/") || t.StartsWith('@') || t.StartsWith('#')) return true;
        // Whole lines of code or shell: operators, flags, assignments, or mostly symbols.
        if (CodeLine().IsMatch(t)) return true;
        var visible = t.Where(c => !char.IsWhiteSpace(c)).ToList();
        if (visible.Count >= 8 && visible.Count(c => "[]{}()<>=;:/\\|&$#*_~`'\"".Contains(c)) / (double)visible.Count > 0.18) return true;
        if (t.Contains(' ')) return false;
        if (t.Contains('@') && t.Contains('.')) return true;
        return FileName().IsMatch(t) || CodeLike().IsMatch(t);
    }

    /// Short labels come back lowercase from some engines ("send"); match sentence case
    /// when the source script has no case of its own.
    public static string CaseMatched(string t, string original)
    {
        if (t.Length == 0 || !char.IsLower(t[0])) return t;
        var o = original.FirstOrDefault(char.IsLetter);
        if (o != default && (char.IsUpper(o) || char.IsLower(o))) return char.IsUpper(o) ? char.ToUpper(t[0]) + t[1..] : t;
        return char.ToUpper(t[0]) + t[1..];
    }
}

/// Language detection. Windows has no built-in detector like Apple's NaturalLanguage, so this
/// decides by script: a text written in a script that only the target uses (kana, hangul,
/// Devanagari for hi/mr…) is already in the target. Latin and Cyrillic targets are left to
/// Google, whose reply marks lines that are already in the target language.
public static class Detect
{
    enum Script { Latin, Cyrillic, Greek, Arabic, Hebrew, Devanagari, Bengali, Gurmukhi, Gujarati, Tamil, Telugu, Kannada, Malayalam, Thai, Hangul, Kana, Han, Other }

    static Script Of(char c) => c switch
    {
        >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= 'À' and <= 'ɏ' or >= 'Ḁ' and <= 'ỿ' => Script.Latin,
        >= 'Ѐ' and <= 'ӿ' => Script.Cyrillic,
        >= 'Ͱ' and <= 'Ͽ' => Script.Greek,
        >= '؀' and <= 'ۿ' or >= 'ݐ' and <= 'ݿ' => Script.Arabic,
        >= '֐' and <= '׿' => Script.Hebrew,
        >= 'ऀ' and <= 'ॿ' => Script.Devanagari,
        >= 'ঀ' and <= '৿' => Script.Bengali,
        >= '਀' and <= '੿' => Script.Gurmukhi,
        >= '઀' and <= '૿' => Script.Gujarati,
        >= '஀' and <= '௿' => Script.Tamil,
        >= 'ఀ' and <= '౿' => Script.Telugu,
        >= 'ಀ' and <= '೿' => Script.Kannada,
        >= 'ഀ' and <= 'ൿ' => Script.Malayalam,
        >= '฀' and <= '๿' => Script.Thai,
        >= '가' and <= '힯' or >= 'ᄀ' and <= 'ᇿ' => Script.Hangul,
        >= '぀' and <= 'ヿ' => Script.Kana,
        >= '一' and <= '鿿' or >= '㐀' and <= '䶿' => Script.Han,
        _ => Script.Other,
    };

    /// Scripts that identify a target language on their own.
    static readonly Dictionary<string, Script[]> Unique = new()
    {
        ["ja"] = [Script.Kana], ["ko"] = [Script.Hangul], ["th"] = [Script.Thai], ["el"] = [Script.Greek],
        ["iw"] = [Script.Hebrew], ["bn"] = [Script.Bengali], ["pa"] = [Script.Gurmukhi], ["gu"] = [Script.Gujarati],
        ["ta"] = [Script.Tamil], ["te"] = [Script.Telugu], ["kn"] = [Script.Kannada], ["ml"] = [Script.Malayalam],
        ["hi"] = [Script.Devanagari], ["mr"] = [Script.Devanagari], ["zh-CN"] = [Script.Han], ["zh-TW"] = [Script.Han],
    };

    /// True when `text` is confidently already in `lang`, so it can be left untouched.
    public static bool IsAlready(string text, Language lang)
    {
        if (text.Length < 4 || !Unique.TryGetValue(lang.Code, out var scripts)) return false;
        var letters = text.Where(char.IsLetter).Select(Of).ToList();
        if (letters.Count == 0) return false;
        // Japanese mixes kana with kanji; Chinese text never has kana.
        if (lang.Code.StartsWith("zh") && letters.Contains(Script.Kana)) return false;
        double share = letters.Count(s => scripts.Contains(s) || (lang.Code == "ja" && s == Script.Han)) / (double)letters.Count;
        if (lang.Code == "ja" && !letters.Contains(Script.Kana)) return false;
        return share > 0.8;
    }

    static readonly (string Code, HashSet<string> Words)[] LatinWords =
    [
        ("en", ["the", "and", "of", "to", "is", "in", "that", "it", "for", "you", "with", "this", "are", "on", "was"]),
        ("es", ["el", "la", "de", "que", "y", "en", "los", "las", "es", "por", "una", "con", "para", "del", "se"]),
        ("fr", ["le", "la", "les", "de", "et", "est", "des", "une", "un", "pour", "que", "dans", "pas", "du", "vous"]),
        ("de", ["der", "die", "und", "das", "ist", "nicht", "ein", "eine", "zu", "mit", "den", "sie", "ich", "auf", "für"]),
        ("it", ["il", "la", "di", "che", "e", "è", "per", "un", "una", "non", "con", "sono", "del", "gli", "le"]),
        ("pt", ["o", "a", "de", "que", "e", "do", "da", "em", "um", "uma", "para", "com", "não", "os", "você"]),
        ("nl", ["de", "het", "een", "en", "van", "is", "dat", "niet", "op", "te", "zijn", "voor", "met", "ik", "je"]),
    ];

    /// The language to read `text` aloud in: its script where that names a language, else
    /// the Latin-script language whose common words it uses most (English when unsure).
    public static string Language(string text)
    {
        var g = Guess(text);
        if (g != "en") return g;
        var words = text.ToLowerInvariant().Split([' ', '\n', '\t', ',', '.', '!', '?', ';', ':', '(', ')', '"'], StringSplitOptions.RemoveEmptyEntries);
        var best = LatinWords.Select(l => (l.Code, Hits: words.Count(l.Words.Contains))).MaxBy(x => x.Hits);
        return best.Hits >= 2 && best.Hits > LatinWords[0].Words.Count(words.Contains) ? best.Code : "en";
    }

    /// Best guess at the source language code, for prompts that name it (TranslateGemma).
    public static string Guess(string text)
    {
        var counts = text.Where(char.IsLetter).GroupBy(Of).OrderByDescending(g => g.Count()).Select(g => g.Key).ToList();
        if (counts.Contains(Script.Kana)) return "ja";
        return counts.FirstOrDefault() switch
        {
            Script.Hangul => "ko", Script.Han => "zh", Script.Cyrillic => "ru", Script.Greek => "el", Script.Arabic => "ar",
            Script.Hebrew => "he", Script.Devanagari => "hi", Script.Bengali => "bn", Script.Thai => "th", Script.Tamil => "ta",
            Script.Telugu => "te", Script.Kannada => "kn", Script.Malayalam => "ml", Script.Gujarati => "gu", Script.Gurmukhi => "pa",
            _ => "en",
        };
    }
}
