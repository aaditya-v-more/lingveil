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

/// Each block is its own layer (a DrawingVisual), painted once; following the app's
/// scrolling only moves layers (shared/SPEC.md §2.12b). A re-read keeps the layer of a block
/// with the same translation at the same spot, so nothing flickers; new blocks fade in over
/// 0.12 s and blocks whose text left fade out. Border, outline, tooltip and status are drawn
/// on a top layer.
public sealed class OverlayView : FrameworkElement
{
    List<Block> blocks = [];
    List<Painter.Laid> laid = [];
    List<DrawingVisual?> layers = [];
    readonly VisualCollection children;
    readonly DrawingVisual top = new();
    double[] shifts = [];
    HashSet<int> hidden = [];
    string? status;
    int? hovered, highlight;
    bool showOriginal;
    readonly DispatcherTimer hoverTimer = new() { Interval = TimeSpan.FromMilliseconds(700) };
    readonly Dictionary<DrawingVisual, (double from, double to, DateTime start, bool remove)> fades = [];

    public bool Interactive { get; init; }
    public bool ShowBorder { get; set; }
    public Action? OnDismiss { get; set; }

    public OverlayView()
    {
        children = new VisualCollection(this) { top };
        hoverTimer.Tick += (_, _) => { hoverTimer.Stop(); showOriginal = true; DrawTop(); };
        SizeChanged += (_, _) => DrawTop();
    }

    protected override int VisualChildrenCount => children.Count;
    protected override Visual GetVisualChild(int index) => children[index];

    public IReadOnlyList<Block> Blocks
    {
        get => blocks;
        set => Show(value, null, null);
    }

    /// Where each block is now relative to where it was read (points, down is positive).
    public IReadOnlyList<double> Shifts => shifts;

    /// Shows `value`, each moved by `shift` and those in `hide` hidden, keeping the layer of
    /// any block that looks the same as one already showing.
    public void Show(IReadOnlyList<Block> value, IReadOnlyList<double>? shift, ISet<int>? hide)
    {
        var old = new Dictionary<string, DrawingVisual>();
        for (int i = 0; i < blocks.Count; i++) if (layers[i] is { } l) old.TryAdd(Key(blocks[i], laid[i], i < shifts.Length ? shifts[i] : 0), l);
        blocks = [.. value];
        double ppd = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        laid = Painter.LayoutAll(blocks, new Rect(0, 0, ActualWidth, ActualHeight), ppd);
        shifts = Enumerable.Range(0, blocks.Count).Select(i => shift != null && i < shift.Count ? shift[i] : 0).ToArray();
        hidden = hide != null ? [.. hide] : [];
        var style = Settings.Current.Style;
        var next = new List<DrawingVisual?>();
        bool first = old.Count == 0;
        for (int i = 0; i < blocks.Count; i++)
        {
            if (laid[i].Dropped) { next.Add(null); continue; }
            if (old.Remove(Key(blocks[i], laid[i], shifts[i]), out var keep))
            {
                keep.Transform = new TranslateTransform(0, shifts[i]);
                if (hidden.Contains(i)) keep.Opacity = 0; else if (keep.Opacity < 1 && !fades.ContainsKey(keep)) Fade(keep, 1);
                next.Add(keep);
                continue;
            }
            var v = new DrawingVisual { Transform = new TranslateTransform(0, shifts[i]) };
            using (var dc = v.RenderOpen()) Painter.Draw(dc, blocks[i], laid[i], style);
            children.Insert(children.Count - 1, v);
            if (hidden.Contains(i)) v.Opacity = 0;
            else if (!first) { v.Opacity = 0; Fade(v, 1); }
            next.Add(v);
        }
        foreach (var gone in old.Values) Fade(gone, 0, remove: true);
        layers = next;
        hovered = null; showOriginal = false;
        DrawTop();
    }

    /// Moves finished layers: no text is laid out or drawn again.
    public void Move(IReadOnlyList<double> shift, ISet<int> hide)
    {
        for (int i = 0; i < layers.Count; i++)
        {
            if (layers[i] is not { } l) continue;
            double s = i < shift.Count ? shift[i] : 0;
            if (i < shifts.Length) shifts[i] = s;
            ((TranslateTransform)l.Transform).Y = s;
            bool was = hidden.Contains(i), now = hide.Contains(i);
            if (was != now) Fade(l, now ? 0 : 1);
        }
        hidden = [.. hide];
        if (highlight != null) DrawTop();
    }

    /// A block read aloud gets a 2 pt accent outline.
    public int? Highlight { get => highlight; set { if (highlight != value) { highlight = value; DrawTop(); } } }

    public string? Status { get => status; set { status = value; DrawTop(); } }

    static string Key(Block b, Painter.Laid l, double shift) => $"{b.Translation}|{Math.Round(l.Box.X)}|{Math.Round(l.Box.Y + shift)}|{Math.Round(l.Box.Width)}";

    void Fade(DrawingVisual v, double to, bool remove = false)
    {
        if (fades.Count == 0) CompositionTarget.Rendering += Animate;
        fades[v] = (v.Opacity, to, DateTime.UtcNow, remove);
    }

    void Animate(object? sender, EventArgs e)
    {
        foreach (var (v, f) in fades.ToList())
        {
            double t = Math.Min(1, (DateTime.UtcNow - f.start).TotalMilliseconds / 120);
            v.Opacity = f.from + (f.to - f.from) * t;
            if (t < 1) continue;
            fades.Remove(v);
            if (f.remove) children.Remove(v);
        }
        if (fades.Count == 0) CompositionTarget.Rendering -= Animate;
    }

    Rect BoxOf(int i) { var r = laid[i].Box; r.Offset(0, i < shifts.Length ? shifts[i] : 0); return r; }

    void DrawTop()
    {
        var all = new Rect(RenderSize);
        double ppd = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        using var dc = top.RenderOpen();
        if (ShowBorder)
        {
            var r = all; r.Inflate(-1, -1);
            var a = SystemColors.HighlightColor;
            dc.DrawRoundedRectangle(null, new Pen(new SolidColorBrush(Color.FromArgb(180, a.R, a.G, a.B)), 2), r, 6, 6);
        }
        if (highlight is { } h && h < laid.Count && !laid[h].Dropped)
        {
            var r = BoxOf(h); r.Inflate(3, 2);
            var a = SystemColors.HighlightColor;
            dc.DrawRoundedRectangle(null, new Pen(new SolidColorBrush(Color.FromArgb(230, a.R, a.G, a.B)), 2), r, 4, 4);
        }
        if (hovered is { } hv && showOriginal && hv < blocks.Count) Painter.DrawTooltip(dc, blocks[hv].Item.Text, BoxOf(hv), all, ppd);
        if (status != null) Painter.DrawPill(dc, status, all, ppd);
    }

    protected override void OnRender(DrawingContext dc)
    {
        // A nearly transparent fill so clicks anywhere on an interactive overlay reach it.
        dc.DrawRectangle(Interactive ? new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)) : Brushes.Transparent, null, new Rect(RenderSize));
    }

    int? IndexAt(Point p)
    {
        for (int i = 0; i < laid.Count; i++) if (!laid[i].Dropped && !hidden.Contains(i) && BoxOf(i).Contains(p)) return i;
        return null;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var i = IndexAt(e.GetPosition(this));
        hoverTimer.Stop();
        if (i != hovered) { showOriginal = false; hovered = i; DrawTop(); }
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
        Add("Copy All Translations", () => Clipboard.SetText(string.Join("\n", ReadingOrder.Order(blocks.Select(b => b.Item.Rect).ToList()).Select(k => blocks[k].Translation))));
        Add("Read Aloud", () => ReadAloud.ReadOverlay(this));
        Add("Close", () => OnDismiss?.Invoke());
        m.PlacementTarget = this;
        m.IsOpen = true;
        e.Handled = true;
    }
}
