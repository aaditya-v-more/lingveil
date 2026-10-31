using System.Windows.Input;
using System.Windows.Interop;

namespace Lingveil.App;

/// A shortcut as stored in settings: "Alt+Shift+T".
public readonly record struct Shortcut(uint Mods, uint Key)
{
    public static Shortcut? Parse(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        uint mods = 0, key = 0;
        foreach (var part in s.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            switch (part.ToLowerInvariant())
            {
                case "alt": mods |= Native.MOD_ALT; break;
                case "ctrl" or "control": mods |= Native.MOD_CONTROL; break;
                case "shift": mods |= Native.MOD_SHIFT; break;
                case "win": mods |= Native.MOD_WIN; break;
                default:
                    if (!Enum.TryParse<Key>(part, true, out var k)) return null;
                    key = (uint)KeyInterop.VirtualKeyFromKey(k);
                    break;
            }
        }
        return key == 0 ? null : new Shortcut(mods, key);
    }

    public override string ToString()
    {
        var parts = new List<string>();
        if ((Mods & Native.MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((Mods & Native.MOD_ALT) != 0) parts.Add("Alt");
        if ((Mods & Native.MOD_SHIFT) != 0) parts.Add("Shift");
        if ((Mods & Native.MOD_WIN) != 0) parts.Add("Win");
        parts.Add(KeyInterop.KeyFromVirtualKey((int)Key).ToString());
        return string.Join("+", parts);
    }
}

/// System-wide shortcuts through RegisterHotKey on a hidden message window. Needs no
/// keyboard hook, so nothing is read except the registered keys.
public sealed class HotKeys
{
    public static readonly HotKeys Shared = new();
    readonly HwndSource window;
    readonly Dictionary<int, Action> handlers = [];
    int nextId = 1;

    HotKeys()
    {
        window = new HwndSource(new HwndSourceParameters("Lingveil hotkeys") { ParentWindow = new IntPtr(-3) });   // HWND_MESSAGE
        window.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if (msg == 0x0312 && handlers.TryGetValue(w.ToInt32(), out var a)) { handled = true; a(); }   // WM_HOTKEY
            return IntPtr.Zero;
        });
    }

    /// Returns an id for Unregister, or null when another app already owns the shortcut.
    public int? Register(Shortcut s, Action handler)
    {
        int id = nextId++;
        if (!Native.RegisterHotKey(window.Handle, id, s.Mods | Native.MOD_NOREPEAT, s.Key)) return null;
        handlers[id] = handler;
        return id;
    }

    public void Unregister(int? id)
    {
        if (id is not { } i) return;
        Native.UnregisterHotKey(window.Handle, i);
        handlers.Remove(i);
    }
}
