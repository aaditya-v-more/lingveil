using System.Runtime.InteropServices;
using Lingveil.Core;
using SkiaSharp;

namespace Lingveil.App;

/// Reads pixels off the screen.
static unsafe class Capture
{
    /// The area of the root window as BGRA pixels (the screen as it is drawn, so call this
    /// before showing our own overlay). `scale` is pixels per point.
    public static Snapshot Grab(IntPtr d, nuint root, int x, int y, int w, int h, double scale)
    {
        var img = X11.XGetImage(d, root, x, y, (uint)w, (uint)h, nuint.MaxValue, X11.ZPixmap);
        if (img == IntPtr.Zero) throw new LingveilException("Couldn't read the screen");
        try
        {
            int bpp = Marshal.ReadInt32(img, 48), stride = Marshal.ReadInt32(img, 44);
            if (bpp != 32) throw new LingveilException($"Unsupported screen format ({bpp} bits per pixel)");
            byte* src = (byte*)Marshal.ReadIntPtr(img, 16);
            var px = new PixelBuffer(w, h);
            byte* dst = (byte*)px.Base;
            for (int row = 0; row < h; row++)
            {
                Buffer.MemoryCopy(src + (long)row * stride, dst + (long)row * w * 4, w * 4, w * 4);
                byte* a = dst + (long)row * w * 4 + 3;
                for (int i = 0; i < w; i++) a[i * 4] = 255;   // X leaves the unused byte as 0
            }
            return new Snapshot(px, scale);
        }
        finally { X11.XDestroyImage(img); }
    }
}

/// A transparent window over the screen that doesn't take clicks or focus: the translation
/// is painted into it and everything not painted stays see-through. It needs a compositing
/// window manager (GNOME, KDE and most others have one) for the transparency.
sealed unsafe class Overlay : IDisposable
{
    readonly IntPtr d;
    readonly nuint cmap;
    readonly IntPtr gc, visual;
    SKBitmap? current;
    public nuint Window { get; }
    public int Width { get; }
    public int Height { get; }

    public Overlay(IntPtr d, int screen, nuint root, int x, int y, int w, int h)
    {
        this.d = d; Width = w; Height = h;
        if (X11.XMatchVisualInfo(d, screen, 32, X11.TrueColor, out var vi) == 0)
            throw new LingveilException("This display has no transparent (32-bit) visual; a compositing window manager is required");
        visual = vi.visual;
        cmap = X11.XCreateColormap(d, root, visual, X11.AllocNone);
        var attrs = new X11.XSetWindowAttributes { colormap = cmap, override_redirect = 1, event_mask = (nint)X11.ExposureMask };
        // back pixel, border pixel, override redirect, event mask, colormap
        Window = X11.XCreateWindow(d, root, x, y, (uint)w, (uint)h, 0, 32, 1 /* InputOutput */, visual, 2 | 8 | 512 | 2048 | 8192, ref attrs);
        // An empty input region: every click and scroll goes to the window underneath.
        X11.XShapeCombineRectangles(d, Window, X11.ShapeInput, 0, 0, IntPtr.Zero, 0, X11.ShapeSet, 0);
        gc = X11.XCreateGC(d, Window, 0, IntPtr.Zero);
        X11.XMapRaised(d, Window);
        X11.XFlush(d);
    }

    /// Replaces what is painted. Takes ownership of `bitmap` (BGRA, premultiplied).
    public void Show(SKBitmap bitmap)
    {
        current?.Dispose();
        current = bitmap;
        Repaint();
    }

    public void Repaint()
    {
        if (current == null) return;
        var img = X11.XCreateImage(d, visual, 32, X11.ZPixmap, 0, current.GetPixels(), (uint)Width, (uint)Height, 32, 0);
        X11.XPutImage(d, Window, gc, img, 0, 0, 0, 0, (uint)Width, (uint)Height);
        Marshal.WriteIntPtr(img, 16, IntPtr.Zero);   // the pixels belong to Skia, not to X
        X11.XDestroyImage(img);
        X11.XFlush(d);
    }

    public void Dispose()
    {
        X11.XDestroyWindow(d, Window);
        X11.XFreeGC(d, gc);
        X11.XFreeColormap(d, cmap);
        X11.XFlush(d);
        current?.Dispose();
        current = null;
    }
}
