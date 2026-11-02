using System.Windows;
using Lingveil.Core;

namespace Lingveil.App;

/// Read Aloud (Alt+Shift+R) and Translate and Read Aloud (Alt+Shift+E), shared/SPEC.md §2.14.
///
/// What gets read, in order of preference: the translation that is showing, the selected
/// text, otherwise the front window's text in reading order. The block being read is
/// outlined on screen. The same shortcut, or Esc, stops it.
public static class ReadAloud
{
    public static async void Read()
    {
        if (Narrator.Shared.IsSpeaking) { Narrator.Shared.Stop(); return; }
        if (OneShot.Shared.DebugView is { Blocks.Count: > 0 } v) { ReadOverlay(v); return; }
        var sel = await Task.Run(Bubble.SelectedText);
        if (!string.IsNullOrWhiteSpace(sel)) { Narrator.Shared.Read([new Segment(sel, null, null)], _ => { }); return; }
        ReadWindow();
    }

    public static async void TranslateAndRead()
    {
        if (Narrator.Shared.IsSpeaking) { Narrator.Shared.Stop(); return; }
        if (OneShot.Shared.DebugView is { Blocks.Count: > 0 } v) { ReadOverlay(v); return; }
        var sel = await Task.Run(Bubble.SelectedText);
        if (!string.IsNullOrWhiteSpace(sel)) { Bubble.Shared.Selection(speak: true); return; }
        var mon = Native.UnderCursor;
        var front = Native.ForegroundFrame() is { } f ? Native.Intersect(f, mon.Bounds) : null;
        OneShot.Shared.Run(mon, front, _ => { if (OneShot.Shared.DebugView is { } view) ReadOverlay(view); });
    }

    /// Reads the translations on the overlay in reading order, outlining each block.
    public static void ReadOverlay(OverlayView v)
    {
        // The title bar (window title) isn't content.
        var tb = OneShot.Shared.TitleBar;
        var blocks = v.Blocks.Select((b, i) => (b, i)).Where(x =>
        {
            var r = x.b.Item.Rect;
            return !(tb is { } t && t.Contains(new Point(r.X + r.Width / 2, r.Y + r.Height / 2)));
        }).ToList();
        var order = ReadingOrder.Order(blocks.Select(x => x.b.Item.Rect).ToList());
        var lang = Settings.Current.TargetLanguage.Code;
        var segs = order.Select(k => new Segment(blocks[k].b.Translation, null, lang)).ToList();
        var index = order.Select(k => blocks[k].i).ToList();
        Narrator.Shared.Read(segs, i => v.Highlight = i is { } k ? index[k] : null);
    }

    /// Reads the original text of the front window (or the screen under the pointer).
    public static async void ReadWindow()
    {
        var mon = Native.UnderCursor;
        var frame = Native.ForegroundFrame() is { } f ? Native.Intersect(f, mon.Bounds) : null;
        var area = frame ?? mon.Bounds;
        double k = mon.Scale;
        Tray.Busy(true);
        try
        {
            var items = await Task.Run(async () =>
            {
                using var snap = new Snapshot(Native.Capture(area), k);
                var found = await Pipeline.Items(snap, Settings.Current.UseAccessibility ? () => Uia.Items(area, k) : null);
                // Skip the title bar (window title): it isn't content.
                var titleBar = frame != null ? new Rect(0, 0, area.Width / k, 32) : Rect.Empty;
                return found.Where(i => i.HasLetters && !i.IsLiteral && !titleBar.Contains(new Point(i.Rect.X + i.Rect.Width / 2, i.Rect.Y + i.Rect.Height / 2))).ToList();
            });
            if (items.Count == 0) { Hud.Flash("No text to read here"); return; }
            var order = ReadingOrder.Order(items.Select(i => i.Rect).ToList());
            var segs = Voices.Speakable(order.Select(i =>
            {
                var r = items[i].Rect;
                var px = new Int32Rect(area.X + (int)(r.X * k), area.Y + (int)(r.Y * k), (int)(r.Width * k), (int)(r.Height * k));
                return new Segment(items[i].Text, px, null);
            }).ToList());
            Narrator.Shared.Read(segs, i => { if (i is { } n && segs[n].Rect is { } r) Highlighter.Show(r); else Highlighter.Hide(); });
        }
        catch (Exception e) { Hud.Flash(e.Message); }
        finally { Tray.Busy(false); }
    }
}
