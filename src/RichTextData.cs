using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace Clipman
{
    internal static class RichTextData
    {
        public const int MaxHtmlBytes = 768 * 1024;
        public const int MaxRtfBytes = 1024 * 1024;
        public const int MaxCombinedBytes = 1792 * 1024;

        public static RichTextPayload CaptureFromClipboard()
        {
            string html = string.Empty;
            byte[] rtf = null;

            try
            {
                if (Clipboard.ContainsData(DataFormats.Html))
                {
                    html = ExtractHtmlFragment(ReadClipboardString(DataFormats.Html));
                }
            }
            catch { }

            try
            {
                if (Clipboard.ContainsData(DataFormats.Rtf))
                {
                    var value = ReadClipboardString(DataFormats.Rtf);
                    if (!string.IsNullOrEmpty(value)) rtf = Encoding.UTF8.GetBytes(value);
                }
            }
            catch { }

            return Normalize(new RichTextPayload
            {
                HtmlFragment = html,
                RtfBase64 = rtf == null ? string.Empty : Convert.ToBase64String(rtf),
                PreferredFormat = !string.IsNullOrEmpty(html) ? "Html" : rtf != null ? "Rtf" : string.Empty
            });
        }

        public static void AddToDataObject(DataObject data, RichTextPayload payload)
        {
            AddToDataObject(data, payload, null);
        }

        public static void AddToDataObject(DataObject data, RichTextPayload payload, ClipEntry entry)
        {
            AddToDataObject(data, payload, entry, string.Empty, DateTime.UtcNow);
        }

        internal static void AddToDataObject(
            DataObject data,
            RichTextPayload payload,
            ClipEntry entry,
            string fileDropRoot,
            DateTime nowUtc)
        {
            var normalized = Normalize(payload);
            if (data == null || normalized == null) return;

            RichImageData.AddNativeClipboardFormats(data, normalized, entry, fileDropRoot, nowUtc);

            if (!string.IsNullOrEmpty(normalized.HtmlFragment))
            {
                data.SetData(DataFormats.Html, false, BuildClipboardHtml(normalized.HtmlFragment));
            }

            var rtf = DecodeRtf(normalized.RtfBase64);
            if (rtf != null && rtf.Length > 0)
            {
                data.SetData(DataFormats.Rtf, false, Encoding.UTF8.GetString(rtf));
            }
        }

        public static RichTextPayload Normalize(RichTextPayload payload)
        {
            if (payload == null) return null;
            var html = payload.HtmlFragment ?? string.Empty;
            var htmlBytes = Encoding.UTF8.GetByteCount(html);
            if (htmlBytes > MaxHtmlBytes) html = string.Empty;

            var rtf = DecodeRtf(payload.RtfBase64);
            if (rtf != null && rtf.Length > MaxRtfBytes) rtf = null;
            if (Encoding.UTF8.GetByteCount(html) + (rtf == null ? 0 : rtf.Length) > MaxCombinedBytes)
            {
                if (!string.IsNullOrEmpty(html)) rtf = null;
                else return null;
            }

            if (string.IsNullOrEmpty(html) && (rtf == null || rtf.Length == 0)) return null;
            var preferred = payload.PreferredFormat ?? string.Empty;
            if ((preferred.Equals("Html", StringComparison.OrdinalIgnoreCase) && string.IsNullOrEmpty(html)) ||
                (preferred.Equals("Rtf", StringComparison.OrdinalIgnoreCase) && (rtf == null || rtf.Length == 0)) ||
                (!preferred.Equals("Html", StringComparison.OrdinalIgnoreCase) &&
                 !preferred.Equals("Rtf", StringComparison.OrdinalIgnoreCase)))
            {
                preferred = !string.IsNullOrEmpty(html) ? "Html" : "Rtf";
            }

            return new RichTextPayload
            {
                Version = 1,
                HtmlFragment = html,
                RtfBase64 = rtf == null ? string.Empty : Convert.ToBase64String(rtf),
                PreferredFormat = preferred
            };
        }

        public static RichTextPayload Clone(RichTextPayload payload)
        {
            var normalized = Normalize(payload);
            if (normalized == null) return null;
            return new RichTextPayload
            {
                Version = normalized.Version,
                HtmlFragment = normalized.HtmlFragment,
                RtfBase64 = normalized.RtfBase64,
                PreferredFormat = normalized.PreferredFormat
            };
        }

        public static bool Equivalent(RichTextPayload left, RichTextPayload right)
        {
            var a = Normalize(left);
            var b = Normalize(right);
            if (a == null || b == null) return a == null && b == null;
            return string.Equals(a.HtmlFragment, b.HtmlFragment, StringComparison.Ordinal) &&
                   string.Equals(a.RtfBase64, b.RtfBase64, StringComparison.Ordinal) &&
                   string.Equals(a.PreferredFormat, b.PreferredFormat, StringComparison.OrdinalIgnoreCase);
        }

        public static int DecodedRtfByteCount(string base64)
        {
            var data = DecodeRtf(base64);
            return data == null ? 0 : data.Length;
        }

        public static string ExtractHtmlFragment(string clipboardHtml)
        {
            if (string.IsNullOrEmpty(clipboardHtml)) return string.Empty;
            var startMarker = Regex.Match(clipboardHtml, @"<!--\s*StartFragment\s*-->", RegexOptions.IgnoreCase);
            var endMarker = Regex.Match(clipboardHtml, @"<!--\s*EndFragment\s*-->", RegexOptions.IgnoreCase);
            if (startMarker.Success && endMarker.Success && endMarker.Index > startMarker.Index)
            {
                var start = startMarker.Index + startMarker.Length;
                return BoundHtml(clipboardHtml.Substring(start, endMarker.Index - start));
            }

            var startMatch = Regex.Match(clipboardHtml, @"(?im)^StartFragment:\s*(\d+)");
            var endMatch = Regex.Match(clipboardHtml, @"(?im)^EndFragment:\s*(\d+)");
            int startBytes;
            int endBytes;
            if (startMatch.Success && endMatch.Success &&
                int.TryParse(startMatch.Groups[1].Value, out startBytes) &&
                int.TryParse(endMatch.Groups[1].Value, out endBytes))
            {
                var bytes = Encoding.UTF8.GetBytes(clipboardHtml);
                if (startBytes >= 0 && endBytes > startBytes && endBytes <= bytes.Length)
                {
                    return BoundHtml(Encoding.UTF8.GetString(bytes, startBytes, endBytes - startBytes));
                }
            }
            return BoundHtml(clipboardHtml);
        }

        public static string BuildClipboardHtml(string fragment)
        {
            fragment = BoundHtml(fragment);
            var body = "<html><body><!--StartFragment-->" + fragment + "<!--EndFragment--></body></html>";
            const string template = "Version:1.0\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
            var placeholder = string.Format(template, 0, 0, 0, 0);
            var startHtml = Encoding.UTF8.GetByteCount(placeholder);
            var fragmentPrefix = "<html><body><!--StartFragment-->";
            var startFragment = startHtml + Encoding.UTF8.GetByteCount(fragmentPrefix);
            var endFragment = startFragment + Encoding.UTF8.GetByteCount(fragment);
            var endHtml = startHtml + Encoding.UTF8.GetByteCount(body);
            return string.Format(template, startHtml, endHtml, startFragment, endFragment) + body;
        }

        private static string ReadClipboardString(string format)
        {
            var value = Clipboard.GetData(format);
            var text = value as string;
            if (text != null) return text;
            var bytes = value as byte[];
            if (bytes != null) return Encoding.UTF8.GetString(bytes).TrimEnd('\0');
            var stream = value as MemoryStream;
            if (stream != null) return Encoding.UTF8.GetString(stream.ToArray()).TrimEnd('\0');
            return value == null ? string.Empty : value.ToString();
        }

        private static byte[] DecodeRtf(string base64)
        {
            if (string.IsNullOrEmpty(base64)) return null;
            try { return Convert.FromBase64String(base64); }
            catch { return null; }
        }

        private static string BoundHtml(string html)
        {
            if (string.IsNullOrEmpty(html)) return string.Empty;
            return Encoding.UTF8.GetByteCount(html) <= MaxHtmlBytes ? html : string.Empty;
        }
    }
}
