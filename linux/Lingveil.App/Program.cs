using Lingveil.Core;

// lingveil                                      run in the background; Alt+Shift+T translates the screen
// Test hooks (shared/SPEC.md §4), the same as the Windows app's:
//   lingveil --render in.png out.png [--scale 2]   pipeline on an image, translation painted on
//   lingveil --bench in.txt out.txt                translate lines for bench/score.py
// LINGVEIL_TARGET, LINGVEIL_ENGINE and LINGVEIL_LOCAL_MODEL pick the target and engine.
static class Program
{
    static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length >= 3 && args[0] == "--render")
            {
                double scale = args.Length >= 5 && args[3] == "--scale" ? double.Parse(args[4], System.Globalization.CultureInfo.InvariantCulture) : 1;
                return await Headless.Render(args[1], args[2], scale);
            }
            if (args.Length >= 3 && args[0] == "--bench") return await Headless.Bench(args[1], args[2]);
            if (args.Length == 0) return new Lingveil.App.App().Run();
        }
        catch (Exception e) { Console.Error.WriteLine("error: " + e.Message); return 1; }
        Console.Error.WriteLine("usage: lingveil [--render in.png out.png [--scale N] | --bench in.txt out.txt]");
        return 2;
    }
}
