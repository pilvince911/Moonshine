using System;
using System.IO;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class OPi5Artwork {
    public static byte[] IcoBytes(byte[] input) {
        if (input == null || input.Length < 22 || input.Length > 8388608 ||
            input[0] != 0 || input[1] != 0 || input[2] != 1 || input[3] != 0)
            throw new InvalidOperationException("Fichier ICO invalide.");
        using (var memory = new MemoryStream(input, false))
        using (var icon = new Icon(memory, new Size(256, 256)))
        using (var bitmap = icon.ToBitmap())
        using (var output = new MemoryStream()) {
            bitmap.Save(output, ImageFormat.Png);
            return output.ToArray();
        }
    }
    public static byte[] IconBytes(string path) {
        // Extract only a file's icon. The executable is never started or loaded
        // as application code by this helper.
        using (var icon = Icon.ExtractAssociatedIcon(path)) {
            if (icon == null) throw new InvalidOperationException("Aucune icone de jeu disponible.");
            using (var bitmap = icon.ToBitmap())
            using (var normalized = new Bitmap(48, 48))
            using (var output = new MemoryStream()) {
                using (var graphics = Graphics.FromImage(normalized)) {
                    graphics.Clear(Color.Transparent);
                    graphics.DrawImage(bitmap, new Rectangle(0, 0, 48, 48));
                }
                normalized.Save(output, ImageFormat.Png);
                return output.ToArray();
            }
        }
    }
    public static byte[] Png(byte[] input) {
        if (input == null || input.Length < 24 || input.Length > 8388608)
            throw new InvalidOperationException("Image absente ou trop volumineuse.");
        bool png = input[0] == 137 && input[1] == 80 && input[2] == 78 && input[3] == 71;
        bool jpeg = input[0] == 255 && input[1] == 216 && input[2] == 255;
        if (!png && !jpeg) throw new InvalidOperationException("La pochette doit etre une vraie image PNG ou JPEG.");
        using (var memory = new MemoryStream(input, false))
        using (var image = Image.FromStream(memory, false, true)) {
            if (image.Width < 24 || image.Height < 24 || image.Width > 8192 || image.Height > 8192 ||
                (long)image.Width * image.Height > 40000000)
                throw new InvalidOperationException("Dimensions de pochette invalides.");
            using (var result = new Bitmap(600, 900, PixelFormat.Format32bppArgb)) {
                using (var graphics = Graphics.FromImage(result)) {
                    graphics.Clear(Color.FromArgb(20, 23, 28));
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    double scale = Math.Min(600.0 / image.Width, 900.0 / image.Height);
                    int width = Math.Max(1, (int)Math.Round(image.Width * scale));
                    int height = Math.Max(1, (int)Math.Round(image.Height * scale));
                    graphics.DrawImage(image, new Rectangle((600-width)/2, (900-height)/2, width, height));
                }
                using (var output = new MemoryStream()) {
                    result.Save(output, ImageFormat.Png);
                    return output.ToArray();
                }
            }
        }
    }
}
