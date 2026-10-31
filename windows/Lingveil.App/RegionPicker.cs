using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Controls;

namespace Lingveil.App;

/// Dims the monitor under the pointer and lets the user drag out an area. Esc or
/// right-click cancels. Returns the area in physical pixels.
public static class RegionPicker
{
    /// Set by the debug listener so area and live modes can run without a person dragging.
    public static Int32Rect? DebugRect;

    public static Task<(Native.Monitor, Int32Rect)?> Pick()
    {
        var mon = Native.UnderCursor;
        if (DebugRect is { } d) { DebugRect = null; return Task.FromResult<(Native.Monitor, Int32Rect)?>((Native.MonitorAt(new Native.POINT { X = d.X, Y = d.Y }), d)); }
        var tcs = new TaskCompletionSource<(Native.Monitor, Int32Rect)?>();
        var canvas = new Canvas { Background = new SolidColorBrush(Color.FromArgb(56, 0, 0, 0)), Cursor = Cursors.Cross };
        var box = new Rectangle { Stroke = Brushes.White, StrokeThickness = 1, Fill = new SolidColorBrush(Color.FromArgb(40, 255, 255, 255)), Visibility = Visibility.Collapsed };
        var hint = new TextBlock
        {
            Text = "Drag over the text to translate · Esc to cancel", Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold,
        };
        canvas.Children.Add(box);
        canvas.Children.Add(hint);
        var w = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true,
            ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize, Content = canvas,
        };
        Point? start = null;
        void Finish((Native.Monitor, Int32Rect)? r) { if (tcs.TrySetResult(r)) w.Close(); }
        w.SourceInitialized += (_, _) =>
        {
            var h = new WindowInteropHelper(w).Handle;
            Native.ExcludeFromCapture(h);
            Native.Place(h, mon.Bounds);
        };
        w.Loaded += (_, _) =>
        {
            hint.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(hint, (w.ActualWidth - hint.DesiredSize.Width) / 2);
            Canvas.SetTop(hint, 90);
            w.Activate(); w.Focus();
        };
        canvas.MouseLeftButtonDown += (_, e) => { start = e.GetPosition(canvas); canvas.CaptureMouse(); hint.Visibility = Visibility.Collapsed; };
        canvas.MouseMove += (_, e) =>
        {
            if (start is not { } s) return;
            var p = e.GetPosition(canvas);
            var r = new Rect(s, p);
            Canvas.SetLeft(box, r.X); Canvas.SetTop(box, r.Y);
            box.Width = r.Width; box.Height = r.Height;
            box.Visibility = Visibility.Visible;
        };
        canvas.MouseLeftButtonUp += (_, e) =>
        {
            canvas.ReleaseMouseCapture();
            if (start is not { } s) return;
            var r = new Rect(s, e.GetPosition(canvas));
            if (r.Width < 8 || r.Height < 8) { Finish(null); return; }
            double k = mon.Scale;
            Finish((mon, new Int32Rect(mon.Bounds.X + (int)Math.Round(r.X * k), mon.Bounds.Y + (int)Math.Round(r.Y * k), (int)Math.Round(r.Width * k), (int)Math.Round(r.Height * k))));
        };
        canvas.MouseRightButtonDown += (_, _) => Finish(null);
        w.KeyDown += (_, e) => { if (e.Key == Key.Escape) Finish(null); };
        w.Deactivated += (_, _) => Finish(null);
        w.Show();
        return tcs.Task;
    }
}
