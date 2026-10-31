using System.Runtime.InteropServices;
using Lingveil.Core;

namespace Lingveil.App;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length >= 3 && args[0] == "--render")
        {
            Console();
            double scale = args.Length >= 5 && args[3] == "--scale" ? double.Parse(args[4], System.Globalization.CultureInfo.InvariantCulture) : 2;
            return Headless.Render(args[1], args[2], scale).GetAwaiter().GetResult();
        }
        if (args.Length >= 3 && args[0] == "--bench")
        {
            Console();
            return Headless.Bench(args[1], args[2]).GetAwaiter().GetResult();
        }
        if (args.Length >= 1 && args[0] == "--ocr-languages")
        {
            Console();
            System.Console.WriteLine(string.Join(" ", Ocr.Languages));
            return 0;
        }
        return Tray.Run();
    }

    /// The exe is a GUI app; test modes write to the console they were started from.
    static void Console()
    {
        AttachConsole(-1);
        System.Console.OutputEncoding = System.Text.Encoding.UTF8;
    }
    [DllImport("kernel32")] static extern bool AttachConsole(int pid);
}
