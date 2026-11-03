// Stand-ins for the WPF value types the shared Core files were written against
// (System.Windows.Rect/Point/Size and friends), with the same behavior, so those files
// compile on Linux without changes. See Lingveil.Core.csproj.
namespace System.Windows
{
    public struct Point(double x, double y)
    {
        public double X { get; set; } = x;
        public double Y { get; set; } = y;
    }

    public struct Size(double width, double height)
    {
        public double Width { get; set; } = width;
        public double Height { get; set; } = height;
    }

    /// WPF's Rect: an empty rect has negative width and height (Rect.Empty), Intersect of
    /// rects that don't overlap gives Empty, and Union ignores an empty side.
    public struct Rect
    {
        double x, y, w, h;

        public Rect(double x, double y, double width, double height)
        {
            if (width < 0 || height < 0) throw new ArgumentException("Width and Height can't be negative.");
            this.x = x; this.y = y; w = width; h = height;
        }

        public Rect(Point location, Size size) : this(location.X, location.Y, size.Width, size.Height) { }
        public Rect(Size size) : this(0, 0, size.Width, size.Height) { }

        public static Rect Empty { get; } = new() { x = double.PositiveInfinity, y = double.PositiveInfinity, w = double.NegativeInfinity, h = double.NegativeInfinity };

        public bool IsEmpty => w < 0;
        public double X { readonly get => x; set => x = value; }
        public double Y { readonly get => y; set => y = value; }
        public double Width { readonly get => w; set => w = value; }
        public double Height { readonly get => h; set => h = value; }
        public readonly double Left => x;
        public readonly double Top => y;
        public readonly double Right => IsEmpty ? double.NegativeInfinity : x + w;
        public readonly double Bottom => IsEmpty ? double.NegativeInfinity : y + h;
        public readonly Point TopLeft => new(Left, Top);
        public readonly Size Size => IsEmpty ? new Size(0, 0) : new Size(w, h);

        public readonly bool IntersectsWith(Rect r) =>
            !IsEmpty && !r.IsEmpty && r.Left <= Right && r.Right >= Left && r.Top <= Bottom && r.Bottom >= Top;

        public void Intersect(Rect r)
        {
            if (!IntersectsWith(r)) { this = Empty; return; }
            double nx = Math.Max(Left, r.Left), ny = Math.Max(Top, r.Top);
            w = Math.Max(Math.Min(Right, r.Right) - nx, 0);
            h = Math.Max(Math.Min(Bottom, r.Bottom) - ny, 0);
            x = nx; y = ny;
        }

        public static Rect Intersect(Rect a, Rect b) { a.Intersect(b); return a; }

        public void Union(Rect r)
        {
            if (IsEmpty) { this = r; return; }
            if (r.IsEmpty) return;
            double nx = Math.Min(Left, r.Left), ny = Math.Min(Top, r.Top);
            w = double.IsPositiveInfinity(r.Width) || double.IsPositiveInfinity(w) ? double.PositiveInfinity : Math.Max(Right, r.Right) - nx;
            h = double.IsPositiveInfinity(r.Height) || double.IsPositiveInfinity(h) ? double.PositiveInfinity : Math.Max(Bottom, r.Bottom) - ny;
            x = nx; y = ny;
        }

        public static Rect Union(Rect a, Rect b) { a.Union(b); return a; }

        public void Inflate(double width, double height)
        {
            if (IsEmpty) return;
            x -= width; y -= height;
            w += width * 2; h += height * 2;
            if (w < 0 || h < 0) this = Empty;
        }

        public void Offset(double dx, double dy)
        {
            if (IsEmpty) return;
            x += dx; y += dy;
        }
    }

    public enum TextAlignment { Left, Right, Center, Justify }
    public enum FlowDirection { LeftToRight, RightToLeft }
    public enum TextTrimming { None, CharacterEllipsis, WordEllipsis }

    public readonly record struct FontWeight(int Weight);

    public static class FontWeights
    {
        public static FontWeight Normal { get; } = new(400);
        public static FontWeight SemiBold { get; } = new(600);
        public static FontWeight Bold { get; } = new(700);
    }

    public readonly record struct FontStyle(int Style);
    public static class FontStyles { public static FontStyle Normal { get; } = new(0); }
    public readonly record struct FontStretch(int Stretch);
    public static class FontStretches { public static FontStretch Normal { get; } = new(5); }
}

namespace System.Windows.Media
{
    public readonly record struct Color(byte A, byte R, byte G, byte B)
    {
        public static Color FromRgb(byte r, byte g, byte b) => new(255, r, g, b);
        public static Color FromArgb(byte a, byte r, byte g, byte b) => new(a, r, g, b);
    }

    public abstract class Brush { public void Freeze() { } }
    public sealed class SolidColorBrush(Color color) : Brush { public Color Color { get; } = color; }
    public static class Brushes
    {
        public static Brush Black { get; } = new SolidColorBrush(new Color(255, 0, 0, 0));
        public static Brush White { get; } = new SolidColorBrush(new Color(255, 255, 255, 255));
    }
}
