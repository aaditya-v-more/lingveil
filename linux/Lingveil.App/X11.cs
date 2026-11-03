using System.Runtime.InteropServices;

namespace Lingveil.App;

/// The few Xlib calls Lingveil needs, called straight from libX11 so nothing has to be
/// installed. Everything X-related runs on one thread (the event loop in App.cs).
static unsafe class X11
{
    const string X = "libX11.so.6", Xext = "libXext.so.6", Xi = "libXi.so.6";

    public const int KeyPress = 2, Expose = 12, PropertyNotify = 28, ClientMessage = 33, GenericEvent = 35;
    public const long PropertyChangeMask = 1 << 22;
    public const int XI_RawButtonPress = 15;
    public const int ShiftMask = 1, LockMask = 2, ControlMask = 4, Mod1Mask = 8, Mod2Mask = 16;
    public const long ExposureMask = 1 << 15;
    public const int ZPixmap = 2, TrueColor = 4, AllocNone = 0;
    public const int GrabModeAsync = 1;
    public const int ShapeInput = 2, ShapeSet = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct XSetWindowAttributes
    {
        public IntPtr background_pixmap; public nuint background_pixel; public IntPtr border_pixmap; public nuint border_pixel;
        public int bit_gravity, win_gravity, backing_store; public nuint backing_planes, backing_pixel;
        public int save_under; public nint event_mask, do_not_propagate_mask; public int override_redirect;
        public nuint colormap, cursor;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct XVisualInfo
    {
        public IntPtr visual; public nuint visualid; public int screen, depth, @class;
        public nuint red_mask, green_mask, blue_mask; public int colormap_size, bits_per_rgb;
    }

    public delegate int ErrorHandler(IntPtr display, IntPtr errorEvent);

    [DllImport(X)] public static extern IntPtr XOpenDisplay(string? name);
    [DllImport(X)] public static extern int XCloseDisplay(IntPtr d);
    [DllImport(X)] public static extern int XDefaultScreen(IntPtr d);
    [DllImport(X)] public static extern nuint XRootWindow(IntPtr d, int screen);
    [DllImport(X)] public static extern int XDisplayWidth(IntPtr d, int screen);
    [DllImport(X)] public static extern int XDisplayHeight(IntPtr d, int screen);
    [DllImport(X)] public static extern int XPending(IntPtr d);
    [DllImport(X)] public static extern int XNextEvent(IntPtr d, byte* ev);
    [DllImport(X)] public static extern int XFlush(IntPtr d);
    [DllImport(X)] public static extern int XSync(IntPtr d, int discard);
    [DllImport(X)] public static extern IntPtr XSetErrorHandler(ErrorHandler h);
    [DllImport(X)] public static extern nuint XStringToKeysym(string s);
    [DllImport(X)] public static extern byte XKeysymToKeycode(IntPtr d, nuint keysym);
    [DllImport(X)] public static extern int XGrabKey(IntPtr d, int keycode, uint modifiers, nuint grabWindow, int ownerEvents, int pointerMode, int keyboardMode);
    [DllImport(X)] public static extern int XUngrabKey(IntPtr d, int keycode, uint modifiers, nuint grabWindow);
    [DllImport(X)] public static extern int XSelectInput(IntPtr d, nuint w, nint mask);
    [DllImport(X)] public static extern int XMatchVisualInfo(IntPtr d, int screen, int depth, int @class, out XVisualInfo info);
    [DllImport(X)] public static extern nuint XCreateColormap(IntPtr d, nuint w, IntPtr visual, int alloc);
    [DllImport(X)] public static extern nuint XCreateWindow(IntPtr d, nuint parent, int x, int y, uint w, uint h, uint border, int depth, uint @class, IntPtr visual, nuint valuemask, ref XSetWindowAttributes attrs);
    [DllImport(X)] public static extern int XDestroyWindow(IntPtr d, nuint w);
    [DllImport(X)] public static extern int XMapRaised(IntPtr d, nuint w);
    [DllImport(X)] public static extern int XUnmapWindow(IntPtr d, nuint w);
    [DllImport(X)] public static extern int XMoveResizeWindow(IntPtr d, nuint w, int x, int y, uint width, uint height);
    [DllImport(X)] public static extern IntPtr XCreateGC(IntPtr d, nuint w, nuint mask, IntPtr values);
    [DllImport(X)] public static extern int XFreeGC(IntPtr d, IntPtr gc);
    [DllImport(X)] public static extern int XFreeColormap(IntPtr d, nuint cmap);
    [DllImport(X)] public static extern IntPtr XCreateImage(IntPtr d, IntPtr visual, uint depth, int format, int offset, IntPtr data, uint w, uint h, int pad, int bytesPerLine);
    [DllImport(X)] public static extern int XPutImage(IntPtr d, nuint drawable, IntPtr gc, IntPtr image, int sx, int sy, int dx, int dy, uint w, uint h);
    [DllImport(X)] public static extern int XDestroyImage(IntPtr image);
    [DllImport(X)] public static extern IntPtr XGetImage(IntPtr d, nuint drawable, int x, int y, uint w, uint h, nuint planeMask, int format);
    [DllImport(X)] public static extern int XQueryPointer(IntPtr d, nuint w, out nuint root, out nuint child, out int rx, out int ry, out int wx, out int wy, out uint mask);
    [DllImport(X)] public static extern nuint XInternAtom(IntPtr d, string name, int onlyIfExists);
    [DllImport(X)] public static extern int XGetEventData(IntPtr d, byte* cookie);
    [DllImport(X)] public static extern void XFreeEventData(IntPtr d, byte* cookie);
    [DllImport(Xi)] public static extern int XIQueryVersion(IntPtr d, ref int major, ref int minor);
    [DllImport(Xi)] public static extern int XISelectEvents(IntPtr d, nuint w, byte* mask, int count);
    [DllImport(Xext)] public static extern void XShapeCombineRectangles(IntPtr d, nuint w, int kind, int xOff, int yOff, IntPtr rects, int n, int op, int ordering);
}
