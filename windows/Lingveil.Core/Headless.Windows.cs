using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Lingveil.Core;

/// WPF image I/O for the headless hooks.
public static partial class Headless
{
    public static PixelBuffer Load(string path)
    {
        var frame = BitmapDecoder.Create(new Uri(Path.GetFullPath(path)), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0];
        var bgra = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
        var px = new PixelBuffer(bgra.PixelWidth, bgra.PixelHeight);
        bgra.CopyPixels(Int32Rect.Empty, px.Base, px.Count, px.Stride);
        return px;
    }

    public static void Write(Snapshot snap, IEnumerable<Block> blocks, string path)
    {
        var src = BitmapSource.Create(snap.Pixels.Width, snap.Pixels.Height, 96 * snap.Scale, 96 * snap.Scale, PixelFormats.Bgra32, null,
                                      snap.Pixels.Base, snap.Pixels.Count, snap.Pixels.Stride);
        var v = new DrawingVisual();
        using (var dc = v.RenderOpen())
        {
            dc.DrawImage(src, new Rect(snap.Size));
            Painter.DrawAll(dc, blocks.ToList(), new Rect(snap.Size), Settings.Current.Style, snap.Scale);
        }
        var rtb = new RenderTargetBitmap(snap.Pixels.Width, snap.Pixels.Height, 96 * snap.Scale, 96 * snap.Scale, PixelFormats.Pbgra32);
        rtb.Render(v);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(rtb));
        using var f = File.Create(path);
        enc.Save(f);
    }
}
