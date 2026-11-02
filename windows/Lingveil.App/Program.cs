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
        if (args.Length >= 2 && args[0] == "--download")
        {
            Console();
            var m = LocalModel.Named(args[1]) ?? throw new ArgumentException("unknown model " + args[1]);
            ModelStore.Download(m, new Progress<double>(p => System.Console.WriteLine($"{p:P0}")), CancellationToken.None).GetAwaiter().GetResult();
            System.Console.WriteLine("installed " + ModelStore.PathOf(m));
            return 0;
        }
        // The narration helper: stdin/stdout are pipes to the app (see TtsHost).
        if (args.Length >= 5 && args[0] == "--tts") return TtsHost.Run(args[1], args[2], args[3], int.Parse(args[4]));
        if (args.Length >= 2 && args[0] == "--say")
        {
            // Test: speak a line with a downloaded model into a WAV file: --say <model id> <out.wav> <text>
            Console();
            var m = VoiceCatalog.Models.First(v => v.Id == args[1]);
            var wav = TtsHelper.For(m).Wav(string.Join(" ", args[3..]), m.Speaker("en"), 1, "en", CancellationToken.None).GetAwaiter().GetResult();
            File.WriteAllBytes(args[2], wav);
            TtsHelper.StopAll();
            System.Console.WriteLine($"wrote {wav.Length} bytes");
            return 0;
        }
        if (args.Length >= 2 && args[0] == "--voice-download")
        {
            Console();
            var m = VoiceCatalog.Models.First(v => v.Id == args[1]);
            VoiceStore.Download(m, new Progress<double>(p => System.Console.WriteLine($"{p:P0}")), CancellationToken.None).GetAwaiter().GetResult();
            System.Console.WriteLine("installed " + VoiceStore.PathOf(m));
            return 0;
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
