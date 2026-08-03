using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Clipman
{
    internal static class LinkPresentation
    {
        internal const int MaximumUrlCharacters = 8192;

        private static readonly HashSet<string> DocumentExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            ".html", ".htm", ".php", ".asp", ".aspx", ".jsp", ".pdf", ".txt", ".md"
        };

        private static readonly HashSet<string> StructuralSegments = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "p", "page", "view", "index", "default", "home"
        };

        public static bool TryGetUri(ClipEntry entry, out Uri uri)
        {
            return TryGetUri(entry == null ? null : entry.Text, out uri);
        }

        public static bool TryGetUri(string text, out Uri uri)
        {
            uri = null;
            if (string.IsNullOrEmpty(text) || text.Length > MaximumUrlCharacters) return false;
            return LinkClassifier.TryGetLinkOnlyUri(text, out uri) && IsUrlWithinLimit(uri);
        }

        internal static bool IsUrlWithinLimit(Uri uri)
        {
            return uri != null && (uri.OriginalString ?? string.Empty).Length <= MaximumUrlCharacters;
        }

        public static string DisplayText(ClipEntry entry)
        {
            Uri uri;
            if (!TryGetUri(entry, out uri)) return string.Empty;
            var destination = Destination(uri);
            var name = SanitizeLabel(entry.Name, 200);
            var label = name.Length > 0 ? name : OfflineLabel(uri);
            if (string.IsNullOrWhiteSpace(label) || string.Equals(label, destination, StringComparison.CurrentCultureIgnoreCase))
            {
                return destination;
            }
            return label + "; " + destination;
        }

        public static string SearchText(ClipEntry entry)
        {
            Uri uri;
            if (!TryGetUri(entry, out uri)) return string.Empty;
            return string.Join(" ", new[]
            {
                SanitizeLabel(entry.Name, 200),
                OfflineLabel(uri),
                Destination(uri),
                (entry.Text ?? string.Empty).Trim()
            }.Where(value => !string.IsNullOrWhiteSpace(value)).ToArray());
        }

        public static string TypeAheadText(ClipEntry entry)
        {
            Uri uri;
            if (!TryGetUri(entry, out uri)) return (entry == null ? string.Empty : entry.Text ?? string.Empty).TrimStart();
            var name = SanitizeLabel(entry.Name, 200);
            return name.Length > 0 ? name : OfflineLabel(uri);
        }

        public static string Destination(Uri uri)
        {
            if (!IsUrlWithinLimit(uri)) return string.Empty;
            var host = DisplayHost(uri);
            var port = uri.IsDefaultPort ? string.Empty : ":" + uri.Port;
            var path = SafeUnescape(uri.AbsolutePath ?? string.Empty).Trim();
            if (path == "/") path = string.Empty;
            if (path.Length > 90) path = path.Substring(0, 87) + "...";
            return host + port + path;
        }

        public static string OfflineLabel(Uri uri)
        {
            if (!IsUrlWithinLimit(uri)) return string.Empty;
            var host = DisplayHost(uri);
            var rawSegments = (uri.AbsolutePath ?? string.Empty)
                .Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(SafeUnescape)
                .Where(segment => !string.IsNullOrWhiteSpace(segment))
                .ToList();

            string numeric = null;
            for (var index = rawSegments.Count - 1; index >= 0; index--)
            {
                var segment = rawSegments[index].Trim();
                if (Regex.IsMatch(segment, @"^\d+$", RegexOptions.CultureInvariant))
                {
                    if (numeric == null) numeric = segment;
                    continue;
                }
                segment = RemoveDocumentExtension(segment);
                if (StructuralSegments.Contains(segment) || IsUuid(segment) || IsHighEntropy(segment)) continue;
                var readable = MakeReadable(segment);
                if (readable.Length == 0) continue;
                if (numeric != null) readable += " " + numeric;
                return readable;
            }
            return host;
        }

        private static string DisplayHost(Uri uri)
        {
            var host = SanitizeLabel(uri == null ? string.Empty : uri.DnsSafeHost, 255).TrimEnd('.');
            if (host.StartsWith("www.", StringComparison.OrdinalIgnoreCase)) host = host.Substring(4);
            return host;
        }

        private static string RemoveDocumentExtension(string value)
        {
            var extension = Path.GetExtension(value ?? string.Empty);
            return DocumentExtensions.Contains(extension) ? value.Substring(0, value.Length - extension.Length) : value;
        }

        private static string MakeReadable(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return string.Empty;
            var builder = new StringBuilder(value.Length);
            foreach (var character in value)
            {
                builder.Append(character == '-' || character == '_' ? ' ' : character);
            }
            var readable = SanitizeLabel(builder.ToString(), 100);
            if (readable.Length == 0) return string.Empty;
            if (readable.All(character => !char.IsLetter(character) || char.IsLower(character)))
            {
                readable = char.ToUpper(readable[0]) + readable.Substring(1);
            }
            return readable.Length > 100 ? readable.Substring(0, 97) + "..." : readable;
        }

        private static bool IsUuid(string value)
        {
            Guid ignored;
            return Guid.TryParse(value, out ignored);
        }

        private static bool IsHighEntropy(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length < 24) return false;
            var letters = value.Count(char.IsLetter);
            var digits = value.Count(char.IsDigit);
            var separators = value.Count(character => character == '-' || character == '_' || character == '.');
            return letters > 5 && digits > 5 && separators <= 3;
        }

        private static string SafeUnescape(string value)
        {
            if (!string.IsNullOrEmpty(value) && value.Length > MaximumUrlCharacters) return string.Empty;
            string decoded;
            try { decoded = Uri.UnescapeDataString(value ?? string.Empty); }
            catch { decoded = value ?? string.Empty; }
            return SanitizeLabel(decoded, 512);
        }

        internal static string SanitizeLabel(string value, int maximumScalars)
        {
            if (string.IsNullOrEmpty(value) || maximumScalars < 1) return string.Empty;
            var builder = new StringBuilder(Math.Min(value.Length, maximumScalars * 2));
            var scalars = 0;
            var pendingSpace = false;
            for (var index = 0; index < value.Length && scalars < maximumScalars;)
            {
                var character = value[index];
                UnicodeCategory category;
                var width = 1;
                if (char.IsHighSurrogate(character))
                {
                    if (index + 1 >= value.Length || !char.IsLowSurrogate(value[index + 1]))
                    {
                        index++;
                        continue;
                    }
                    category = CharUnicodeInfo.GetUnicodeCategory(value, index);
                    width = 2;
                }
                else
                {
                    if (char.IsLowSurrogate(character))
                    {
                        index++;
                        continue;
                    }
                    category = char.GetUnicodeCategory(character);
                }

                var codePoint = width == 2 ? char.ConvertToUtf32(value, index) : character;
                if (codePoint == 0xfffd || category == UnicodeCategory.Format || category == UnicodeCategory.Surrogate)
                {
                    index += width;
                    continue;
                }
                if (category == UnicodeCategory.Control || category == UnicodeCategory.LineSeparator ||
                    category == UnicodeCategory.ParagraphSeparator || category == UnicodeCategory.SpaceSeparator ||
                    (width == 1 && char.IsWhiteSpace(character)))
                {
                    pendingSpace = builder.Length > 0;
                    index += width;
                    continue;
                }
                if (pendingSpace && builder.Length > 0) builder.Append(' ');
                builder.Append(value, index, width);
                pendingSpace = false;
                scalars++;
                index += width;
            }
            return builder.ToString();
        }
    }
}
