using System;

namespace Clipman
{
    internal static class LinkClassifier
    {
        public static bool IsLinkOnlyText(string text)
        {
            var trimmed = (text ?? string.Empty).Trim();
            if (trimmed.Length == 0) return false;
            if (trimmed.IndexOfAny(new[] { '\r', '\n' }) >= 0) return false;

            Uri uri;
            if (!Uri.TryCreate(trimmed, UriKind.Absolute, out uri)) return false;
            if (!string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(uri.Scheme, "clipman", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            return !string.IsNullOrWhiteSpace(uri.Host);
        }
    }
}
