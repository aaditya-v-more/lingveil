using System.Windows;
using Lingveil.Core;

namespace Lingveil.App;

/// Copy Text from Area (Alt+Shift+C, shared/SPEC.md §2.12c): drag over any part of the
/// screen and its text goes on the clipboard as plain text. Uses the app's own text where UI
/// Automation has it (exact characters), otherwise reads it from the pixels, and keeps the
/// reading order and line breaks.
public static class CopyText
{
    public static string? Last { get; private set; }

    public static async void Area()
    {
        Last = null;
        if (await RegionPicker.Pick("Drag over the text to copy · Esc to cancel") is not var (mon, area)) return;
        Tray.Busy(true);
        try
        {
            var items = await Task.Run(async () =>
            {
                using var snap = new Snapshot(Native.Capture(area), mon.Scale);
                var found = await Pipeline.Items(snap, Settings.Current.UseAccessibility ? () => Uia.Items(area, mon.Scale) : null);
                return found.Where(i => !string.IsNullOrWhiteSpace(i.Text)).ToList();
            });
            if (items.Count == 0) { Hud.Flash(Ocr.MissingHint() ?? "No text found there"); return; }
            var text = ReadingOrder.Arrange(items);
            Clipboard.SetText(text);
            Last = text;
            int lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length;
            Hud.Flash(lines == 1 ? $"Copied: {(text.Length > 40 ? text[..40] + "…" : text)}" : $"Copied {lines} lines of text");
            Hud.Used();
        }
        catch (Exception e) { Hud.Flash(e.Message); }
        finally { Tray.Busy(false); }
    }
}
