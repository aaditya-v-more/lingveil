using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;

namespace Lingveil.Core;

/// One piece of on-screen text to translate. `Rect` is the glyph area in points of the
/// captured image, origin top-left (see shared/SPEC.md).
public record struct TextItem(string Text, Rect Rect, int Lines)
{
    public string? FontFamily { get; set; }     // known only for UI Automation text
    public double? FontSize { get; set; }       // exact (UIA) or estimated (OCR) size in points
    public TextAlignment Align { get; set; } = TextAlignment.Left;
    public bool FromUia { get; set; }
    public double? GlyphHeight { get; set; }    // median height of the single OCR lines a paragraph was merged from
    public double? LinesWidth { get; set; }     // summed width of those lines

    public readonly double LineHeight => Rect.Height / Math.Max(1, Lines);
    public readonly bool IsCJK => Text.Any(c => c is >= '぀' and <= '鿿' || c is >= '가' and <= '힯');
    public readonly bool HasLetters => Text.Any(char.IsLetter);
    public readonly bool IsLiteral => Filters.IsLiteral(Text);
}

/// A translated piece of text, ready to paint, with what was measured around it.
public record Block(TextItem Item, string Translation, Palette Palette, Surroundings Around);

public enum GradientAxis { None, Vertical, Horizontal }

/// Colors sampled around and inside a piece of text. `Top`/`Bottom` are the gradient ends
/// (left/right for a horizontal one); `Background` is the ring's most common color.
public record Palette(Rgb Top, Rgb Bottom, Rgb Text, Rgb Background, GradientAxis Axis = GradientAxis.None)
{
    public static readonly Palette Fallback = new(new(1, 1, 1), new(1, 1, 1), new(0.1, 0.1, 0.1), new(1, 1, 1));
}

public readonly record struct Rgb(double R, double G, double B)
{
    public double Luma => 0.2126 * R + 0.7152 * G + 0.0722 * B;
    public double Dist(Rgb o) => Math.Sqrt((R - o.R) * (R - o.R) + (G - o.G) * (G - o.G) + (B - o.B) * (B - o.B));
    public Rgb Mix(Rgb o, double t) => new(R + (o.R - R) * t, G + (o.G - G) * t, B + (o.B - B) * t);
    public Color Color => Color.FromRgb(To8(R), To8(G), To8(B));
    static byte To8(double v) => (byte)Math.Clamp(Math.Round(v * 255), 0, 255);

    static int Bucket(Rgb c) => (int)(c.R * 15.99) << 8 | (int)(c.G * 15.99) << 4 | (int)(c.B * 15.99);

    /// Average of the most common 16-level color bucket.
    public static Rgb Mode(IReadOnlyList<Rgb> s)
    {
        var buckets = new Dictionary<int, (int n, double r, double g, double b)>();
        foreach (var c in s)
        {
            var v = buckets.GetValueOrDefault(Bucket(c));
            buckets[Bucket(c)] = (v.n + 1, v.r + c.R, v.g + c.G, v.b + c.B);
        }
        if (buckets.Count == 0) return new(1, 1, 1);
        var best = buckets.Values.MaxBy(v => v.n);
        return new(best.r / best.n, best.g / best.n, best.b / best.n);
    }

    /// Share of the most common bucket: 1 for a flat color.
    public static double Purity(IReadOnlyList<Rgb> s) => s.Count == 0 ? 0 : s.GroupBy(Bucket).Max(g => g.Count()) / (double)s.Count;

    public static Rgb Median(IReadOnlyList<Rgb> s)
    {
        static double M(IEnumerable<double> v) { var a = v.ToArray(); Array.Sort(a); return a[a.Length / 2]; }
        return new(M(s.Select(c => c.R)), M(s.Select(c => c.G)), M(s.Select(c => c.B)));
    }
}

/// sRGB BGRA pixels, top-left origin. A 1080p screen is ~8 MB; the buffer comes from
/// native memory and is released with Dispose when the overlay closes, so it never sits
/// in the managed large-object heap between uses.
public sealed unsafe class PixelBuffer : IDisposable
{
    public int Width { get; }
    public int Height { get; }
    public int Stride => Width * 4;
    public int Count => Width * Height * 4;
    public IntPtr Base { get; private set; }

    public PixelBuffer(int width, int height)
    {
        if (width <= 0 || height <= 0) throw new ArgumentException("empty image");
        Width = width; Height = height;
        Base = (IntPtr)NativeMemory.Alloc((nuint)Count);
    }

    public Span<byte> Span => new((void*)Base, Count);

    public Rgb Pixel(int x, int y)
    {
        byte* p = (byte*)Base + (y * Width + x) * 4;
        return new Rgb(p[2] / 255.0, p[1] / 255.0, p[0] / 255.0);
    }

    public void Dispose()
    {
        if (Base == IntPtr.Zero) return;
        NativeMemory.Free((void*)Base);
        Base = IntPtr.Zero;
        GC.SuppressFinalize(this);
    }

    ~PixelBuffer() { if (Base != IntPtr.Zero) NativeMemory.Free((void*)Base); }
}

/// A captured piece of the screen: pixels plus how many pixels make one point.
public sealed class Snapshot(PixelBuffer pixels, double scale) : IDisposable
{
    public PixelBuffer Pixels { get; } = pixels;
    public double Scale { get; } = scale;
    public Size Size => new(Pixels.Width / Scale, Pixels.Height / Scale);

    public Rect PixelRect(Rect r) => new(r.X * Scale, r.Y * Scale, r.Width * Scale, r.Height * Scale);
    public void Dispose() => Pixels.Dispose();
}

public class LingveilException(string message) : Exception(message);
