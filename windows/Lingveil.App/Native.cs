using System.Runtime.InteropServices;
using System.Windows;
using Lingveil.Core;

namespace Lingveil.App;

/// Win32 calls the app needs. Coordinates are physical pixels (the app is per-monitor DPI aware).
public static class Native
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; public Int32Rect ToRect() => new(Left, Top, Right - Left, Bottom - Top); }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }

    [DllImport("user32")] public static extern bool RegisterHotKey(IntPtr hwnd, int id, uint mods, uint vk);
    [DllImport("user32")] public static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32")] public static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
    [DllImport("user32")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
    [DllImport("shcore")] static extern int GetDpiForMonitor(IntPtr mon, int type, out uint x, out uint y);
    [DllImport("user32")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("dwmapi")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);
    [DllImport("user32")] public static extern bool SetForegroundWindow(IntPtr hwnd);

    public const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_SHIFT = 4, MOD_WIN = 8, MOD_NOREPEAT = 0x4000;
    public const uint WDA_NONE = 0, WDA_EXCLUDEFROMCAPTURE = 0x11;
    public const int VK_MENU = 0x12, VK_ESCAPE = 0x1B;

    public record Monitor(Int32Rect Bounds, Int32Rect Work, double Scale);

    public static POINT Cursor { get { GetCursorPos(out var p); return p; } }

    public static Monitor MonitorAt(POINT p)
    {
        var h = MonitorFromPoint(p, 2);   // nearest
        var mi = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(h, ref mi);
        GetDpiForMonitor(h, 0, out var dpi, out _);
        return new Monitor(mi.Monitor.ToRect(), mi.Work.ToRect(), dpi / 96.0);
    }

    public static Monitor UnderCursor => MonitorAt(Cursor);

    /// Keeps a window out of screenshots and screen capture (including our own), so live mode
    /// never reads its own overlay. LINGVEIL_DEBUG_CAPTURE_OVERLAY=1 turns it off for checks.
    public static void ExcludeFromCapture(IntPtr hwnd, bool exclude = true)
    {
        if (Environment.GetEnvironmentVariable("LINGVEIL_DEBUG_CAPTURE_OVERLAY") == "1") exclude = false;
        SetWindowDisplayAffinity(hwnd, exclude ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE);
    }

    /// Tool window that never takes focus; optionally click-through.
    public static void MakeOverlay(IntPtr hwnd, bool clickThrough)
    {
        const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TRANSPARENT = 0x20, WS_EX_LAYERED = 0x80000;
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
        if (clickThrough) ex |= WS_EX_TRANSPARENT | WS_EX_LAYERED;
        SetWindowLong(hwnd, GWL_EXSTYLE, ex);
    }

    /// Places a window exactly on a physical-pixel rect, topmost, without activating it.
    public static void Place(IntPtr hwnd, Int32Rect r) =>
        SetWindowPos(hwnd, new IntPtr(-1), r.X, r.Y, r.Width, r.Height, 0x0010 | 0x0040);   // NOACTIVATE | SHOWWINDOW

    /// Visible frame of the foreground window (without the invisible resize border).
    public static Int32Rect? ForegroundFrame()
    {
        var h = GetForegroundWindow();
        if (h == IntPtr.Zero || IsOurs(h)) return null;
        return DwmGetWindowAttribute(h, 9, out var r, Marshal.SizeOf<RECT>()) == 0 ? r.ToRect() : null;   // DWMWA_EXTENDED_FRAME_BOUNDS
    }

    public static bool IsOurs(IntPtr hwnd)
    {
        GetWindowThreadProcessId(hwnd, out var pid);
        return pid == Environment.ProcessId;
    }

    public static bool AltDown => (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;

    // MARK: capture

    [DllImport("user32")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("gdi32")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER { public int Size, Width, Height; public short Planes, BitCount; public int Compression, SizeImage, XPels, YPels, ClrUsed, ClrImportant; }

    /// Copies a physical-pixel rect of the desktop into a new buffer. Windows marked
    /// WDA_EXCLUDEFROMCAPTURE (all of ours) are left out by the system.
    public static unsafe PixelBuffer Capture(Int32Rect r)
    {
        var screen = GetDC(IntPtr.Zero);
        var mem = CreateCompatibleDC(screen);
        var bmi = new BITMAPINFOHEADER { Size = 40, Width = r.Width, Height = -r.Height, Planes = 1, BitCount = 32 };
        var dib = CreateDIBSection(screen, ref bmi, 0, out var bits, IntPtr.Zero, 0);
        try
        {
            var old = SelectObject(mem, dib);
            BitBlt(mem, 0, 0, r.Width, r.Height, screen, r.X, r.Y, 0x00CC0020 | 0x40000000);   // SRCCOPY | CAPTUREBLT
            SelectObject(mem, old);
            var px = new PixelBuffer(r.Width, r.Height);
            Buffer.MemoryCopy((void*)bits, (void*)px.Base, px.Count, px.Count);
            // GDI leaves alpha at 0; make it opaque.
            byte* p = (byte*)px.Base;
            for (int i = 3; i < px.Count; i += 4) p[i] = 255;
            return px;
        }
        finally
        {
            DeleteObject(dib); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen);
        }
    }
}
