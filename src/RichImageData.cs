using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class RichImageInfo : IDisposable
    {
        public string FileName { get; set; }
        public string MimeType { get; set; }
        public byte[] Data { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public Image Image { get; set; }

        public void Dispose()
        {
            if (Image != null) Image.Dispose();
            Image = null;
        }
    }

    internal sealed class RichImageCapture
    {
        public string Text { get; set; }
        public RichTextPayload RichText { get; set; }
        public int ImageBytes { get; set; }
    }

    internal static class RichImageData
    {
        public const int MaximumStoredImageBytes = 512 * 1024;
        public const int MaximumInputBytes = 16 * 1024 * 1024;
        public const int MaximumPixels = 16 * 1024 * 1024;
        public const int MaximumDimension = 4096;
        public const int OptimizedMaximumDimension = 2048;
        public const long MaximumDatabaseImageBytes = 8L * 1024L * 1024L;

        private const string Prefix = "<img data-clipman-image=\"1\" data-clipman-filename=\"";
        private const string AltMarker = "\" alt=\"";
        private const string SourceMarker = "\" src=\"data:";
        private const string Base64Marker = ";base64,";
        private const string Suffix = "\">";

        public static bool ClipboardHasStandaloneImage()
        {
            try
            {
                if (Clipboard.ContainsImage()) return true;
                var data = Clipboard.GetDataObject();
                return data != null && new[] { "PNG", "image/png", "JFIF", "image/jpeg" }.Any(data.GetDataPresent);
            }
            catch { return false; }
        }

        public static RichImageCapture CaptureFromClipboard()
        {
            byte[] original;
            string mime;
            if (!TryReadRawClipboardImage(out original, out mime))
            {
                Image clipboardImage;
                try { clipboardImage = Clipboard.GetImage(); }
                catch { return null; }
                if (clipboardImage == null) return null;
                using (clipboardImage)
                {
                    if (!DimensionsAllowed(clipboardImage.Width, clipboardImage.Height)) return null;
                    original = Optimize(clipboardImage, "image/png", null, out mime);
                }
            }
            return CreateCapture(original, mime, string.Empty);
        }

        public static bool TryGetSingleClipboardImageFile(out string path, out string failureMessage)
        {
            path = string.Empty;
            failureMessage = string.Empty;
            StringCollection files;
            try
            {
                if (!Clipboard.ContainsFileDropList()) return false;
                files = Clipboard.GetFileDropList();
            }
            catch
            {
                failureMessage = "Could not read copied files from the clipboard.";
                return false;
            }
            if (files == null || files.Count != 1)
            {
                failureMessage = "Copy exactly one PNG or JPEG file before pasting into Rich Text history.";
                return false;
            }
            var candidate = files[0];
            if (string.IsNullOrWhiteSpace(candidate) || !File.Exists(candidate) || Directory.Exists(candidate))
            {
                failureMessage = "The copied image file is no longer available.";
                return false;
            }
            if (MimeForImageFileName(candidate).Length == 0)
            {
                failureMessage = "Only a copied PNG or JPEG file can be pasted into Rich Text history.";
                return false;
            }
            path = candidate;
            return true;
        }

        public static RichImageCapture CaptureFromFile(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path) || Directory.Exists(path)) return null;
            var expectedMime = MimeForImageFileName(path);
            if (expectedMime.Length == 0) return null;
            byte[] original;
            try
            {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (stream.Length <= 0 || stream.Length > MaximumInputBytes) return null;
                    original = DataBytes(stream);
                }
            }
            catch
            {
                return null;
            }
            if (original == null || !MatchesMime(original, expectedMime)) return null;
            return CreateCapture(original, expectedMime, Path.GetFileName(path));
        }

        private static RichImageCapture CreateCapture(byte[] original, string mime, string requestedFileName)
        {
            if (original == null || original.Length == 0 || original.Length > MaximumInputBytes) return null;
            if (!MatchesMime(original, mime)) return null;
            if (mime == "image/png" && IsAnimatedPng(original)) return null;

            byte[] stored = original;
            int width;
            int height;
            if (!TryReadDimensions(original, mime, out width, out height) || !DimensionsAllowed(width, height)) return null;
            using (var source = LoadImage(original, out width, out height))
            {
                if (source == null || !DimensionsAllowed(width, height)) return null;
                if (stored.Length > MaximumStoredImageBytes || width > OptimizedMaximumDimension || height > OptimizedMaximumDimension)
                {
                    stored = Optimize(source, mime, ReadMetadata(source), out mime);
                }
            }
            if (stored == null || stored.Length == 0 || stored.Length > MaximumStoredImageBytes) return null;

            var extension = mime == "image/png" ? ".png" : ".jpg";
            var fileName = string.IsNullOrWhiteSpace(requestedFileName) ? "Clipboard image" + extension : NormalizeFileName(requestedFileName, mime);
            var html = BuildHtml(stored, mime, fileName, "Image: " + fileName);
            if (Encoding.UTF8.GetByteCount(html) > RichTextData.MaxHtmlBytes) return null;
            return new RichImageCapture
            {
                Text = FallbackText(fileName, stored),
                ImageBytes = stored.Length,
                RichText = new RichTextPayload
                {
                    Version = 1,
                    HtmlFragment = html,
                    RtfBase64 = string.Empty,
                    PreferredFormat = "Html"
                }
            };
        }

        private static string MimeForImageFileName(string path)
        {
            var extension = Path.GetExtension(path ?? string.Empty);
            if (string.Equals(extension, ".png", StringComparison.OrdinalIgnoreCase)) return "image/png";
            if (string.Equals(extension, ".jpg", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(extension, ".jpeg", StringComparison.OrdinalIgnoreCase)) return "image/jpeg";
            return string.Empty;
        }

        public static string BuildHtml(byte[] data, string mimeType, string fileName, string alternateText)
        {
            if (data == null) return string.Empty;
            var mime = NormalizeMime(mimeType);
            if (mime.Length == 0) return string.Empty;
            var canonicalFileName = NormalizeFileName(fileName, mime);
            var canonicalAlternateText = "Image: " + canonicalFileName;
            return Prefix + Attribute(canonicalFileName, 120) + AltMarker + Attribute(canonicalAlternateText, 200) + SourceMarker + mime + Base64Marker + Convert.ToBase64String(data) + Suffix;
        }

        public static bool TryDecode(RichTextPayload payload, out RichImageInfo info)
        {
            return TryDecode(payload, true, out info);
        }

        public static bool TryDescribe(RichTextPayload payload, out RichImageInfo info)
        {
            return TryDecode(payload, false, out info);
        }

        private static bool TryDecode(RichTextPayload payload, bool loadBitmap, out RichImageInfo info)
        {
            info = null;
            if (payload == null || string.IsNullOrEmpty(payload.HtmlFragment)) return false;
            var html = payload.HtmlFragment;
            if (!html.StartsWith(Prefix, StringComparison.Ordinal) || !html.EndsWith(Suffix, StringComparison.Ordinal)) return false;
            var fileEnd = html.IndexOf(AltMarker, Prefix.Length, StringComparison.Ordinal);
            if (fileEnd < 0) return false;
            var altStart = fileEnd + AltMarker.Length;
            var altEnd = html.IndexOf(SourceMarker, altStart, StringComparison.Ordinal);
            if (altEnd < 0) return false;
            var mimeStart = altEnd + SourceMarker.Length;
            var base64Start = html.IndexOf(Base64Marker, mimeStart, StringComparison.Ordinal);
            if (base64Start < 0) return false;
            var mime = NormalizeMime(html.Substring(mimeStart, base64Start - mimeStart));
            if (mime.Length == 0) return false;
            var encodedStart = base64Start + Base64Marker.Length;
            var encodedLength = html.Length - Suffix.Length - encodedStart;
            if (encodedLength <= 0 || encodedLength > ((MaximumStoredImageBytes + 2) / 3) * 4 + 4) return false;

            byte[] data;
            try { data = Convert.FromBase64String(html.Substring(encodedStart, encodedLength)); }
            catch { return false; }
            if (data.Length == 0 || data.Length > MaximumStoredImageBytes) return false;
            if (!MatchesMime(data, mime)) return false;
            if (mime == "image/png" && IsAnimatedPng(data)) return false;
            int width;
            int height;
            if (!TryReadDimensions(data, mime, out width, out height) || !StoredDimensionsAllowed(width, height)) return false;
            var encodedFileName = html.Substring(Prefix.Length, fileEnd - Prefix.Length);
            var fileName = HttpUtility.HtmlDecode(encodedFileName);
            if (!IsCanonicalFileName(fileName, mime)) return false;
            var encodedAlternateText = html.Substring(altStart, altEnd - altStart);
            var alternateText = HttpUtility.HtmlDecode(encodedAlternateText);
            if (!string.Equals(alternateText, "Image: " + fileName, StringComparison.Ordinal)) return false;
            if (!string.Equals(Attribute(fileName, 120), encodedFileName, StringComparison.Ordinal) ||
                !string.Equals(Attribute(alternateText, 200), encodedAlternateText, StringComparison.Ordinal) ||
                !string.Equals(BuildHtml(data, mime, fileName, alternateText), html, StringComparison.Ordinal)) return false;
            Image image = null;
            if (loadBitmap) image = LoadImage(data, out width, out height);
            if ((loadBitmap && image == null) || !StoredDimensionsAllowed(width, height))
            {
                if (image != null) image.Dispose();
                return false;
            }
            info = new RichImageInfo
            {
                FileName = fileName,
                MimeType = mime,
                Data = data,
                Width = width,
                Height = height,
                Image = image
            };
            return true;
        }

        public static int StoredByteCount(RichTextPayload payload)
        {
            RichImageInfo info;
            if (!TryDescribe(payload, out info)) return 0;
            using (info) return info.Data == null ? 0 : info.Data.Length;
        }

        public static string FallbackText(string fileName, byte[] data)
        {
            var cleanName = HttpUtility.HtmlDecode(Attribute(fileName, 120));
            if (string.IsNullOrWhiteSpace(cleanName)) cleanName = "Clipboard image";
            using (var sha256 = SHA256.Create())
            {
                var digest = sha256.ComputeHash(data ?? new byte[0]);
                var fingerprint = string.Concat(digest.Take(6).Select(value => value.ToString("x2")).ToArray());
                return "Image: " + cleanName + " (" + fingerprint + ")";
            }
        }

        public static bool AddNativeClipboardFormats(DataObject target, RichTextPayload payload)
        {
            return AddNativeClipboardFormats(target, payload, null);
        }

        public static bool AddNativeClipboardFormats(DataObject target, RichTextPayload payload, ClipEntry entry)
        {
            return AddNativeClipboardFormats(target, payload, entry, string.Empty, DateTime.UtcNow);
        }

        internal static bool AddNativeClipboardFormats(
            DataObject target,
            RichTextPayload payload,
            ClipEntry entry,
            string fileDropRoot,
            DateTime nowUtc)
        {
            if (target == null) return false;
            RichImageInfo info;
            if (!TryDecode(payload, out info)) return false;
            using (info)
            {
                var bitmap = new Bitmap(info.Image);
                target.SetImage(bitmap);
                target.SetData(info.MimeType == "image/png" ? "PNG" : "JFIF", false, new MemoryStream(info.Data, false));
                if (entry != null)
                {
                    var fileName = BuildExplorerFileName(entry, info.MimeType);
                    if (string.IsNullOrWhiteSpace(fileDropRoot)) RichImageFileDropData.Add(target, info.Data, fileName);
                    else RichImageFileDropData.Add(target, info.Data, fileName, fileDropRoot, nowUtc);
                }
            }
            return true;
        }

        internal static string BuildExplorerFileName(ClipEntry entry, string mimeType)
        {
            var created = EntryCreatedTime(entry);
            var device = NormalizeVirtualFileStem(entry == null ? string.Empty : entry.SourceMachine, 80);
            if (device.Length == 0) device = "Unknown device";
            var extension = string.Equals(NormalizeMime(mimeType), "image/png", StringComparison.Ordinal) ? ".png" : ".jpg";
            return "Clipman image " + created.ToString("yyyy-MM-dd HH-mm-ss", CultureInfo.InvariantCulture) + " - " + device + extension;
        }

        private static DateTime EntryCreatedTime(ClipEntry entry)
        {
            try
            {
                return entry != null && entry.CreatedUnixMs > 0 ? TimeUtil.FromUnixMs(entry.CreatedUnixMs) : DateTime.Now;
            }
            catch
            {
                return DateTime.Now;
            }
        }

        private static string NormalizeVirtualFileStem(string value, int maximumScalars)
        {
            var raw = HasWellFormedUtf16(value) ? (value ?? string.Empty).Trim() : string.Empty;
            var invalid = new HashSet<char>(Path.GetInvalidFileNameChars());
            var clean = new StringBuilder();
            var pendingSpace = false;
            for (var index = 0; index < raw.Length; index++)
            {
                var scalarLength = char.IsHighSurrogate(raw[index]) && index + 1 < raw.Length && char.IsLowSurrogate(raw[index + 1]) ? 2 : 1;
                var category = CharUnicodeInfo.GetUnicodeCategory(raw, index);
                if (char.IsWhiteSpace(raw, index) || category == UnicodeCategory.LineSeparator || category == UnicodeCategory.ParagraphSeparator)
                {
                    pendingSpace = clean.Length > 0;
                    index += scalarLength - 1;
                    continue;
                }
                if (category == UnicodeCategory.Control || category == UnicodeCategory.Format || category == UnicodeCategory.Surrogate ||
                    invalid.Contains(raw[index]))
                {
                    index += scalarLength - 1;
                    continue;
                }
                if (pendingSpace)
                {
                    clean.Append(' ');
                    pendingSpace = false;
                }
                clean.Append(raw, index, scalarLength);
                index += scalarLength - 1;
            }
            return TruncateScalars(clean.ToString().Trim().TrimEnd('.'), maximumScalars).TrimEnd(' ', '.');
        }

        private static bool TryReadRawClipboardImage(out byte[] data, out string mime)
        {
            data = null;
            mime = string.Empty;
            IDataObject clipboard;
            try { clipboard = Clipboard.GetDataObject(); }
            catch { return false; }
            if (clipboard == null) return false;
            foreach (var candidate in new[]
            {
                new KeyValuePair<string, string>("PNG", "image/png"),
                new KeyValuePair<string, string>("image/png", "image/png"),
                new KeyValuePair<string, string>("JFIF", "image/jpeg"),
                new KeyValuePair<string, string>("image/jpeg", "image/jpeg")
            })
            {
                if (!clipboard.GetDataPresent(candidate.Key)) continue;
                var bytes = DataBytes(clipboard.GetData(candidate.Key));
                if (bytes == null || bytes.Length == 0 || bytes.Length > MaximumInputBytes) continue;
                data = bytes;
                mime = candidate.Value;
                return true;
            }
            return false;
        }

        private static byte[] DataBytes(object value)
        {
            var bytes = value as byte[];
            if (bytes != null) return bytes;
            var stream = value as Stream;
            if (stream == null) return null;
            try
            {
                if (stream.CanSeek && stream.Length > MaximumInputBytes) return null;
                using (var output = new MemoryStream())
                {
                    var buffer = new byte[8192];
                    while (output.Length <= MaximumInputBytes)
                    {
                        var read = stream.Read(buffer, 0, Math.Min(buffer.Length, MaximumInputBytes + 1 - (int)output.Length));
                        if (read <= 0) break;
                        output.Write(buffer, 0, read);
                    }
                    return output.Length <= MaximumInputBytes ? output.ToArray() : null;
                }
            }
            catch { return null; }
        }

        private static Image LoadImage(byte[] data, out int width, out int height)
        {
            width = 0;
            height = 0;
            try
            {
                string mime;
                if (MatchesMime(data, "image/png")) mime = "image/png";
                else if (MatchesMime(data, "image/jpeg")) mime = "image/jpeg";
                else return null;
                if (!TryReadDimensions(data, mime, out width, out height) || !DimensionsAllowed(width, height)) return null;
                using (var stream = new MemoryStream(data, false))
                using (var source = Image.FromStream(stream, true, true))
                {
                    if (source.Width != width || source.Height != height || !DimensionsAllowed(source.Width, source.Height)) return null;
                    var copy = new Bitmap(source);
                    CopyBoundedMetadata(copy, ReadMetadata(source));
                    return copy;
                }
            }
            catch { return null; }
        }

        private static bool TryReadDimensions(byte[] data, string mime, out int width, out int height)
        {
            width = 0;
            height = 0;
            if (!MatchesMime(data, mime)) return false;
            if (mime == "image/png")
            {
                if (data.Length < 24) return false;
                width = ReadBigEndianInt32(data, 16);
                height = ReadBigEndianInt32(data, 20);
                return width > 0 && height > 0;
            }

            var position = 2;
            while (position + 3 < data.Length)
            {
                if (data[position] != 0xff) return false;
                while (position < data.Length && data[position] == 0xff) position++;
                if (position >= data.Length) return false;
                var marker = data[position++];
                if (marker == 0xd8 || marker == 0x01) continue;
                if (marker == 0xd9 || marker == 0xda) return false;
                if (position + 1 >= data.Length) return false;
                var segmentLength = (data[position] << 8) | data[position + 1];
                if (segmentLength < 2 || position + segmentLength > data.Length) return false;
                if (IsStartOfFrame(marker))
                {
                    if (segmentLength < 7) return false;
                    height = (data[position + 3] << 8) | data[position + 4];
                    width = (data[position + 5] << 8) | data[position + 6];
                    return width > 0 && height > 0;
                }
                position += segmentLength;
            }
            return false;
        }

        private static bool IsStartOfFrame(byte marker)
        {
            return marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc;
        }

        private static int ReadBigEndianInt32(byte[] data, int offset)
        {
            if (data == null || offset < 0 || offset + 4 > data.Length) return 0;
            var value = ((long)data[offset] << 24) | ((long)data[offset + 1] << 16) | ((long)data[offset + 2] << 8) | data[offset + 3];
            return value > int.MaxValue ? 0 : (int)value;
        }

        private static bool DimensionsAllowed(int width, int height)
        {
            return width > 0 && height > 0 && width <= MaximumDimension && height <= MaximumDimension && (long)width * height <= MaximumPixels;
        }

        private static bool StoredDimensionsAllowed(int width, int height)
        {
            return width > 0 && height > 0 && width <= OptimizedMaximumDimension && height <= OptimizedMaximumDimension;
        }

        private static bool IsAnimatedPng(byte[] data)
        {
            if (!MatchesMime(data, "image/png")) return false;
            var offset = 8;
            while (offset + 12 <= data.Length)
            {
                var length = ReadBigEndianInt32(data, offset);
                if (length < 0 || (long)offset + 12 + length > data.Length) return true;
                var typeOffset = offset + 4;
                if (data[typeOffset] == (byte)'a' && data[typeOffset + 1] == (byte)'c' &&
                    data[typeOffset + 2] == (byte)'T' && data[typeOffset + 3] == (byte)'L') return true;
                offset += 12 + length;
                if (data[typeOffset] == (byte)'I' && data[typeOffset + 1] == (byte)'E' &&
                    data[typeOffset + 2] == (byte)'N' && data[typeOffset + 3] == (byte)'D') return false;
            }
            return true;
        }

        private static byte[] Optimize(Image source, string sourceMime, PropertyItem[] metadata, out string mime)
        {
            mime = sourceMime == "image/png" && HasAlpha(source) ? "image/png" : "image/jpeg";
            var scale = Math.Min(1.0, Math.Min((double)OptimizedMaximumDimension / source.Width, (double)OptimizedMaximumDimension / source.Height));
            var width = Math.Max(1, (int)Math.Round(source.Width * scale));
            var height = Math.Max(1, (int)Math.Round(source.Height * scale));
            using (var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb))
            {
                var horizontalResolution = SafeResolution(source.HorizontalResolution);
                var verticalResolution = SafeResolution(source.VerticalResolution);
                bitmap.SetResolution(horizontalResolution, verticalResolution);
                using (var graphics = Graphics.FromImage(bitmap))
                {
                    graphics.Clear(mime == "image/png" ? Color.Transparent : Color.White);
                    graphics.CompositingQuality = CompositingQuality.HighQuality;
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.SmoothingMode = SmoothingMode.HighQuality;
                    graphics.DrawImage(source, 0, 0, width, height);
                }
                CopyBoundedMetadata(bitmap, metadata);
                if (mime == "image/png")
                {
                    var png = SavePng(bitmap);
                    if (png.Length <= MaximumStoredImageBytes) return png;
                    mime = "image/jpeg";
                }
                foreach (var quality in new long[] { 88, 80, 72, 64, 55, 45 })
                {
                    var jpeg = SaveJpeg(bitmap, quality);
                    if (jpeg.Length <= MaximumStoredImageBytes) return jpeg;
                }
            }
            return null;
        }

        private static float SafeResolution(float value)
        {
            return value >= 1 && value <= 2400 && !float.IsNaN(value) && !float.IsInfinity(value) ? value : 96;
        }

        private static void CopyBoundedMetadata(Image destination, IEnumerable<PropertyItem> items)
        {
            if (destination == null || items == null) return;
            var total = 0;
            foreach (var item in items)
            {
                if (item == null || item.Value == null || item.Value.Length > 16 * 1024 || total + item.Value.Length > 64 * 1024) continue;
                try
                {
                    destination.SetPropertyItem(item);
                    total += item.Value.Length;
                }
                catch { }
            }
        }

        private static PropertyItem[] ReadMetadata(Image image)
        {
            try { return image == null ? new PropertyItem[0] : image.PropertyItems; }
            catch { return new PropertyItem[0]; }
        }

        private static byte[] SavePng(Image image)
        {
            using (var stream = new MemoryStream())
            {
                image.Save(stream, ImageFormat.Png);
                return stream.ToArray();
            }
        }

        private static byte[] SaveJpeg(Image image, long quality)
        {
            using (var stream = new MemoryStream())
            {
                var codec = ImageCodecInfo.GetImageEncoders().First(value => value.FormatID == ImageFormat.Jpeg.Guid);
                using (var parameters = new EncoderParameters(1))
                {
                    parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
                    image.Save(stream, codec, parameters);
                }
                return stream.ToArray();
            }
        }

        private static bool HasAlpha(Image image)
        {
            return image != null && (Image.IsAlphaPixelFormat(image.PixelFormat) || Image.IsExtendedPixelFormat(image.PixelFormat));
        }

        private static string NormalizeMime(string value)
        {
            if (string.Equals(value, "image/png", StringComparison.OrdinalIgnoreCase)) return "image/png";
            if (string.Equals(value, "image/jpeg", StringComparison.OrdinalIgnoreCase) || string.Equals(value, "image/jpg", StringComparison.OrdinalIgnoreCase)) return "image/jpeg";
            return string.Empty;
        }

        private static bool MatchesMime(byte[] data, string mime)
        {
            if (data == null) return false;
            if (mime == "image/png")
            {
                return data.Length >= 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4e && data[3] == 0x47 &&
                       data[4] == 0x0d && data[5] == 0x0a && data[6] == 0x1a && data[7] == 0x0a;
            }
            if (mime == "image/jpeg")
            {
                return data.Length >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff;
            }
            return false;
        }

        private static string Attribute(string value, int maximumLength)
        {
            var text = (value ?? string.Empty).Trim();
            text = TruncateScalars(text, maximumLength);
            return text.Replace("&", "&amp;")
                .Replace("\"", "&quot;")
                .Replace("<", "&lt;")
                .Replace(">", "&gt;");
        }

        private static bool IsCanonicalFileName(string value, string mime)
        {
            return !string.IsNullOrEmpty(value) &&
                   string.Equals(value, NormalizeFileName(value, mime), StringComparison.Ordinal);
        }

        private static string NormalizeFileName(string value, string mime)
        {
            var fallbackExtension = mime == "image/png" ? ".png" : ".jpg";
            var raw = HasWellFormedUtf16(value) ? (value ?? string.Empty).Trim() : string.Empty;
            var lower = raw.ToLowerInvariant();
            if (lower.StartsWith("content:", StringComparison.Ordinal) ||
                lower.StartsWith("file:", StringComparison.Ordinal) ||
                lower.StartsWith("ph:", StringComparison.Ordinal) ||
                lower.StartsWith("assets-library:", StringComparison.Ordinal) ||
                lower.Contains("://"))
            {
                raw = string.Empty;
            }
            else
            {
                raw = raw.Replace('\\', '/');
                var slash = raw.LastIndexOf('/');
                if (slash >= 0) raw = raw.Substring(slash + 1);
                var marker = raw.IndexOfAny(new[] { '?', '#' });
                if (marker >= 0) raw = raw.Substring(0, marker);
            }

            var clean = new StringBuilder();
            var pendingSpace = false;
            for (var index = 0; index < raw.Length; index++)
            {
                var scalarLength = char.IsHighSurrogate(raw[index]) && index + 1 < raw.Length && char.IsLowSurrogate(raw[index + 1]) ? 2 : 1;
                var codePoint = scalarLength == 2 ? char.ConvertToUtf32(raw, index) : raw[index];
                var category = CharUnicodeInfo.GetUnicodeCategory(raw, index);
                if (char.IsWhiteSpace(raw, index) || category == UnicodeCategory.LineSeparator || category == UnicodeCategory.ParagraphSeparator)
                {
                    pendingSpace = clean.Length > 0;
                    index += scalarLength - 1;
                    continue;
                }
                if (category == UnicodeCategory.Control || category == UnicodeCategory.Format || category == UnicodeCategory.Surrogate ||
                    codePoint == 0xfffd || codePoint == '/' || codePoint == '\\')
                {
                    index += scalarLength - 1;
                    continue;
                }
                if (pendingSpace)
                {
                    clean.Append(' ');
                    pendingSpace = false;
                }
                if (codePoint != ':') clean.Append(char.ConvertFromUtf32(codePoint));
                index += scalarLength - 1;
            }

            var normalized = clean.ToString().Trim();
            var normalizedLower = normalized.ToLowerInvariant();
            string extension;
            string stem;
            if (mime == "image/png")
            {
                extension = ".png";
                stem = normalizedLower.EndsWith(".png", StringComparison.Ordinal) ? normalized.Substring(0, normalized.Length - 4) : RemoveImageExtension(normalized);
            }
            else if (normalizedLower.EndsWith(".jpeg", StringComparison.Ordinal))
            {
                extension = ".jpeg";
                stem = normalized.Substring(0, normalized.Length - 5);
            }
            else if (normalizedLower.EndsWith(".jpg", StringComparison.Ordinal))
            {
                extension = ".jpg";
                stem = normalized.Substring(0, normalized.Length - 4);
            }
            else
            {
                extension = fallbackExtension;
                stem = RemoveImageExtension(normalized);
            }
            stem = stem.Trim();
            if (stem.Length == 0 || stem == ".") stem = "Clipboard image";
            stem = TruncateScalars(stem, 120 - ScalarCount(extension)).TrimEnd();
            if (stem.Length == 0) stem = "Clipboard image";
            return stem + extension;
        }

        private static string RemoveImageExtension(string value)
        {
            var lower = (value ?? string.Empty).ToLowerInvariant();
            foreach (var extension in new[] { ".jpeg", ".jpg", ".png" })
            {
                if (lower.EndsWith(extension, StringComparison.Ordinal)) return value.Substring(0, value.Length - extension.Length);
            }
            return value ?? string.Empty;
        }

        private static int ScalarCount(string value)
        {
            var count = 0;
            for (var index = 0; index < (value ?? string.Empty).Length; index++)
            {
                if (char.IsHighSurrogate(value[index]) && index + 1 < value.Length && char.IsLowSurrogate(value[index + 1])) index++;
                count++;
            }
            return count;
        }

        private static bool HasWellFormedUtf16(string value)
        {
            for (var index = 0; index < (value ?? string.Empty).Length; index++)
            {
                if (char.IsHighSurrogate(value[index]))
                {
                    if (index + 1 >= value.Length || !char.IsLowSurrogate(value[index + 1])) return false;
                    index++;
                }
                else if (char.IsLowSurrogate(value[index]))
                {
                    return false;
                }
            }
            return true;
        }

        private static string TruncateScalars(string value, int maximumScalars)
        {
            if (string.IsNullOrEmpty(value) || maximumScalars < 1) return string.Empty;
            var scalars = 0;
            var index = 0;
            while (index < value.Length && scalars < maximumScalars)
            {
                if (char.IsHighSurrogate(value[index]))
                {
                    if (index + 1 < value.Length && char.IsLowSurrogate(value[index + 1])) index += 2;
                    else
                    {
                        index++;
                        continue;
                    }
                }
                else if (char.IsLowSurrogate(value[index]))
                {
                    index++;
                    continue;
                }
                else index++;
                scalars++;
            }
            return index >= value.Length ? value : value.Substring(0, index);
        }
    }
}
