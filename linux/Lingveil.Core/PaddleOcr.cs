using System.Windows;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using SkiaSharp;

namespace Lingveil.Core;

/// PaddleOCR (PP-OCRv6) text detection and recognition through ONNX Runtime: a detector that
/// finds text lines and a recognizer that reads each one. One multilingual model reads
/// Chinese, Japanese, English and the Latin-script languages, which Tesseract does poorly on
/// busy screens. Lines are horizontal boxes (screen text is nearly always horizontal).
public sealed class PaddleOcr : IDisposable
{
    readonly InferenceSession det, rec;
    readonly string[] chars;   // index 0 = CTC blank, then the model's characters, last = space

    public static string Folder { get; } = Environment.GetEnvironmentVariable("LINGVEIL_OCR_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lingveil", "Ocr");

    public static string DetPath => Path.Combine(Folder, "PP-OCRv6_det_small.onnx");
    public static string RecPath => Path.Combine(Folder, "PP-OCRv6_rec_small.onnx");
    public static bool Installed => File.Exists(DetPath) && File.Exists(RecPath);

    static PaddleOcr? shared;
    public static PaddleOcr? Shared => shared ??= Installed ? new PaddleOcr() : null;

    PaddleOcr()
    {
        det = new InferenceSession(DetPath, new SessionOptions { IntraOpNumThreads = Math.Max(2, Environment.ProcessorCount / 2) });
        rec = new InferenceSession(RecPath, new SessionOptions { IntraOpNumThreads = 2 });
        var table = rec.ModelMetadata.CustomMetadataMap["character"].Split('\n');
        chars = [string.Empty, .. table, " "];
    }

    public sealed record Found(Rect Ink, string Text, float Score);

    /// Text lines in image pixels. `Ink` hugs the letters (cap height to baseline or descender).
    public List<Found> Recognize(PixelBuffer px)
    {
        using var src = new SKBitmap();
        src.InstallPixels(new SKImageInfo(px.Width, px.Height, SKColorType.Bgra8888, SKAlphaType.Premul), px.Base, px.Stride);
        var boxes = Detect(src, px);
        var results = new Found?[boxes.Count];
        Parallel.For(0, boxes.Count, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(2, Environment.ProcessorCount / 2) }, i =>
        {
            var (text, score) = Read(src, boxes[i]);
            if (text.Length > 0 && score >= 0.5f) results[i] = new Found(TrimToInk(px, boxes[i]), text, score);
        });
        return results.Where(r => r != null).Select(r => r!).ToList();
    }

    // ---- detection ----

    /// Boxes (image pixels) around each blob the detector marks as text.
    List<Rect> Detect(SKBitmap src, PixelBuffer px)
    {
        // The detector wants sides that are multiples of 32 and text not too small.
        double ratio = Math.Min(px.Width, px.Height) < 736 ? 736.0 / Math.Min(px.Width, px.Height) : 1;
        if (Math.Max(px.Width, px.Height) * ratio > 2880) ratio = 2880.0 / Math.Max(px.Width, px.Height);
        int w = Math.Max(32, (int)Math.Round(px.Width * ratio / 32) * 32), h = Math.Max(32, (int)Math.Round(px.Height * ratio / 32) * 32);
        using var small = w == px.Width && h == px.Height ? src.Copy() : src.Resize(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul), SKFilterQuality.High);
        var t = new DenseTensor<float>([1, 3, h, w]);
        float[] mean = [0.485f, 0.456f, 0.406f], std = [0.229f, 0.224f, 0.225f];   // applied in B, G, R order like PaddleOCR
        var span = small.GetPixelSpan();
        var buf = t.Buffer.Span;
        int plane = w * h;
        for (int i = 0; i < plane; i++)
        {
            buf[i] = (span[i * 4] / 255f - mean[0]) / std[0];
            buf[plane + i] = (span[i * 4 + 1] / 255f - mean[1]) / std[1];
            buf[2 * plane + i] = (span[i * 4 + 2] / 255f - mean[2]) / std[2];
        }
        using var run = det.Run([NamedOnnxValue.CreateFromTensor(det.InputMetadata.Keys.First(), t)]);
        var prob = run.First().AsTensor<float>().ToArray();   // 1×1×h×w

        // Connected blobs above the threshold.
        var seen = new bool[plane];
        var stack = new Stack<int>();
        var boxes = new List<Rect>();
        double sx = (double)px.Width / w, sy = (double)px.Height / h;
        for (int start = 0; start < plane; start++)
        {
            if (seen[start] || prob[start] <= 0.3f) continue;
            int minX = w, maxX = 0, minY = h, maxY = 0, n = 0; double sum = 0;
            stack.Push(start); seen[start] = true;
            while (stack.Count > 0)
            {
                int p = stack.Pop(), x = p % w, y = p / w;
                n++; sum += prob[p];
                if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y;
                if (x > 0 && !seen[p - 1] && prob[p - 1] > 0.3f) { seen[p - 1] = true; stack.Push(p - 1); }
                if (x < w - 1 && !seen[p + 1] && prob[p + 1] > 0.3f) { seen[p + 1] = true; stack.Push(p + 1); }
                if (y > 0 && !seen[p - w] && prob[p - w] > 0.3f) { seen[p - w] = true; stack.Push(p - w); }
                if (y < h - 1 && !seen[p + w] && prob[p + w] > 0.3f) { seen[p + w] = true; stack.Push(p + w); }
            }
            int bw = maxX - minX + 1, bh = maxY - minY + 1;
            if (Math.Min(bw, bh) < 3 || n < 12 || sum / n < 0.5) continue;
            // The detector's blob is a little inside the letters: grow it, more along the line.
            double padX = bh * 0.3, padY = bh * 0.12;
            double x0 = Math.Max(0, (minX - padX) * sx), y0 = Math.Max(0, (minY - padY) * sy);
            double x1 = Math.Min(px.Width, (maxX + 1 + padX) * sx), y1 = Math.Min(px.Height, (maxY + 1 + padY) * sy);
            boxes.Add(new Rect(x0, y0, x1 - x0, y1 - y0));
        }
        return boxes;
    }

    // ---- recognition ----

    (string, float) Read(SKBitmap src, Rect box)
    {
        int bw = (int)box.Width, bh = (int)box.Height;
        if (bw < 2 || bh < 2) return ("", 0);
        int w = Math.Clamp((int)Math.Ceiling(48.0 * bw / bh), 16, 3200);
        using var crop = new SKBitmap(new SKImageInfo(w, 48, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var c = new SKCanvas(crop))
        using (var paint = new SKPaint { FilterQuality = SKFilterQuality.High })
            c.DrawBitmap(src, new SKRect((float)box.Left, (float)box.Top, (float)box.Right, (float)box.Bottom), new SKRect(0, 0, w, 48), paint);
        var t = new DenseTensor<float>([1, 3, 48, w]);
        var span = crop.GetPixelSpan();
        var buf = t.Buffer.Span;
        int plane = 48 * w;
        for (int i = 0; i < plane; i++)
        {
            buf[i] = span[i * 4] / 255f * 2 - 1;
            buf[plane + i] = span[i * 4 + 1] / 255f * 2 - 1;
            buf[2 * plane + i] = span[i * 4 + 2] / 255f * 2 - 1;
        }
        using var run = rec.Run([NamedOnnxValue.CreateFromTensor(rec.InputMetadata.Keys.First(), t)]);
        var o = run.First().AsTensor<float>();
        int steps = o.Dimensions[1], classes = o.Dimensions[2];
        var data = o.ToArray();
        var sb = new System.Text.StringBuilder();
        int last = 0; double conf = 0; int kept = 0;
        for (int s = 0; s < steps; s++)
        {
            int best = 0; float bp = float.MinValue;
            for (int k = 0; k < classes; k++) { var v = data[s * classes + k]; if (v > bp) { bp = v; best = k; } }
            if (best != 0 && best != last && best < chars.Length) { sb.Append(chars[best]); conf += bp; kept++; }
            last = best;
        }
        return (sb.ToString().Trim(), kept == 0 ? 0 : (float)(conf / kept));
    }

    // ---- ink box ----

    /// The detector's box is padded; the letters' own top and bottom rows are what the shared
    /// font-size and line-box rules expect, so find them from the pixels.
    static Rect TrimToInk(PixelBuffer px, Rect box)
    {
        int x0 = (int)box.Left, x1 = Math.Min(px.Width, (int)Math.Ceiling(box.Right));
        int y0 = (int)box.Top, y1 = Math.Min(px.Height, (int)Math.Ceiling(box.Bottom));
        if (x1 - x0 < 3 || y1 - y0 < 3) return box;
        var ring = new List<Rgb>();
        for (int x = x0; x < x1; x += 2) { ring.Add(px.Pixel(x, y0)); ring.Add(px.Pixel(x, y1 - 1)); }
        for (int y = y0; y < y1; y += 2) { ring.Add(px.Pixel(x0, y)); ring.Add(px.Pixel(x1 - 1, y)); }
        var bg = Rgb.Mode(ring);
        int need = Math.Max(1, (x1 - x0) / 80);
        int first = -1, lastRow = -1;
        for (int y = y0; y < y1; y++)
        {
            int n = 0;
            for (int x = x0; x < x1; x++) if (px.Pixel(x, y).Dist(bg) > 0.25 && ++n >= need) break;
            if (n >= need) { if (first < 0) first = y; lastRow = y; }
        }
        if (first < 0 || lastRow - first < 2) return box;
        int c0 = -1, c1 = -1;
        for (int x = x0; x < x1; x++)
        {
            bool ink = false;
            for (int y = first; y <= lastRow && !ink; y++) ink = px.Pixel(x, y).Dist(bg) > 0.25;
            if (ink) { if (c0 < 0) c0 = x; c1 = x; }
        }
        if (c0 < 0) return box;
        return new Rect(c0, first, c1 - c0 + 1, lastRow - first + 1);
    }

    public void Dispose() { det.Dispose(); rec.Dispose(); }
}
