using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Lingveil.Core;

namespace Lingveil.App;

/// Borderless, topmost window over a monitor or area that paints translations in place.
/// It never takes focus and is left out of screen capture.
public sealed class OverlayWindow : Window
{
    public OverlayView View { get; }
    public Int32Rect PixelBounds { get; }

    public OverlayWindow(Int32Rect bounds, bool interactive)
    {
        PixelBounds = bounds;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Opacity = 0;
        View = new OverlayView { Interactive = interactive };
        Content = View;
        SourceInitialized += (_, _) =>
        {
            var h = new WindowInteropHelper(this).Handle;
            Native.MakeOverlay(h, clickThrough: !interactive);
            Native.ExcludeFromCapture(h);
            Native.Place(h, bounds);
        };
    }

    public IntPtr Handle => new WindowInteropHelper(this).Handle;

    public void ShowFaded()
    {
        Show();
        Native.Place(Handle, PixelBounds);
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(120)));
    }

    public void FadeOut(Action? done = null)
    {
        var a = new DoubleAnimation(Opacity, 0, TimeSpan.FromMilliseconds(100));
        a.Completed += (_, _) => { Close(); done?.Invoke(); };
        BeginAnimation(OpacityProperty, a);
    }
}

public sealed class OverlayView : FrameworkElement
{
    List<Block> blocks = [];
    List<Painter.Laid> laid = [];
    string? status;
    int? hovered;
    bool showOriginal;
    readonly DispatcherTimer hoverTimer = new() { Interval = TimeSpan.FromMilliseconds(700) };

    public bool Interactive { get; init; }
    public bool ShowBorder { get; set; }
    public Action? OnDismiss { get; set; }

    public OverlayView()
    {
        hoverTimer.Tick += (_, _) => { hoverTimer.Stop(); showOriginal = true; InvalidateVisual(); };
    }

    public IReadOnlyList<Block> Blocks
    {
        get => blocks;
        set
        {
            blocks = [.. value];
            double ppd = VisualTreeHelper.GetDpi(this).PixelsPerDip;
            laid = blocks.Select(b => Painter.Layout(b, ppd)).ToList();
            hovered = null; showOriginal = false;
            InvalidateVisual();
        }
    }

    public string? Status { get => status; set { status = value; InvalidateVisual(); } }

    protected override void OnRender(DrawingContext dc)
    {
        // A nearly transparent fill so clicks anywhere on an interactive overlay reach it.
        var all = new Rect(RenderSize);
        dc.DrawRectangle(Interactive ? new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)) : Brushes.Transparent, null, all);
        var style = Settings.Current.Style;
        for (int i = 0; i < blocks.Count; i++) Painter.Draw(dc, blocks[i], laid[i], style);
        if (ShowBorder)
        {
            var r = all; r.Inflate(-1, -1);
            dc.DrawRoundedRectangle(null, new Pen(new SolidColorBrush(Color.FromArgb(180, SystemColors.HighlightColor.R, SystemColors.HighlightColor.G, SystemColors.HighlightColor.B)), 2), r, 6, 6);
        }
        double ppd = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        if (hovered is { } h && showOriginal && h < blocks.Count) Painter.DrawTooltip(dc, blocks[h].Item.Text, laid[h].Box, all, ppd);
        if (status != null) Painter.DrawPill(dc, status, all, ppd);
    }

    int? IndexAt(Point p)
    {
        for (int i = 0; i < laid.Count; i++) if (laid[i].Box.Contains(p)) return i;
        return null;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var i = IndexAt(e.GetPosition(this));
        hoverTimer.Stop();
        if (i != hovered) { showOriginal = false; hovered = i; InvalidateVisual(); }
        if (i != null) hoverTimer.Start();
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e) => OnDismiss?.Invoke();
    protected override void OnMouseWheel(MouseWheelEventArgs e) => OnDismiss?.Invoke();

    protected override void OnMouseRightButtonUp(MouseButtonEventArgs e)
    {
        var m = new ContextMenu();
        void Add(string title, Action a) { var mi = new MenuItem { Header = title }; mi.Click += (_, _) => a(); m.Items.Add(mi); }
        if (IndexAt(e.GetPosition(this)) is { } i)
        {
            var b = blocks[i];
            Add("Copy Translation", () => Clipboard.SetText(b.Translation));
            Add("Copy Original", () => Clipboard.SetText(b.Item.Text));
            m.Items.Add(new Separator());
        }
        Add("Copy All Translations", () => Clipboard.SetText(string.Join("\n", blocks.OrderBy(b => b.Item.Rect.Top).Select(b => b.Translation))));
        Add("Close", () => OnDismiss?.Invoke());
        m.PlacementTarget = this;
        m.IsOpen = true;
        e.Handled = true;
    }
}
