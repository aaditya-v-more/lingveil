using System.Windows;
using SkiaSharp;

namespace Lingveil.Core;

/// Image I/O for the headless hooks on Linux (the WPF version is Headless.Windows.cs).
public static partial class Headless
{
    public static PixelBuffer Load(string path)
    {
        using var bmp = SKBitmap.Decode(path) ?? throw new LingveilException("Can't read image " + path);
        var px = new PixelBuffer(bmp.Width, bmp.Height);
        var info = new SKImageInfo(bmp.Width, bmp.Height, SKColorType.Bgra8888, SKAlphaType.Unpremul);
        using var img = SKImage.FromBitmap(bmp);
        if (!img.ReadPixels(info, px.Base, px.Stride, 0, 0)) throw new LingveilException("Can't convert image " + path);
        return px;
    }

    public static void Write(Snapshot snap, IEnumerable<Block> blocks, string path)
    {
        var info = new SKImageInfo(snap.Pixels.Width, snap.Pixels.Height, SKColorType.Bgra8888, SKAlphaType.Unpremul);
        using var src = new SKBitmap();
        src.InstallPixels(info, snap.Pixels.Base, snap.Pixels.Stride);
        using var surface = SKSurface.Create(new SKImageInfo(info.Width, info.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
        var canvas = surface.Canvas;
        canvas.DrawBitmap(src, 0, 0);
        canvas.Scale((float)snap.Scale);
        Painter.DrawAll(canvas, blocks.ToList(), new Rect(snap.Size), Settings.Current.Style, snap.Scale);
        using var png = surface.Snapshot().Encode(SKEncodedImageFormat.Png, 100);
        using var f = File.Create(path);
        png.SaveTo(f);
    }
}
