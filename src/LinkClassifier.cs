using System;
using System.Text.RegularExpressions;

namespace Clipman
{
    internal static class LinkClassifier
    {
        private static readonly Regex TrailingRolePattern = new Regex(
            @"^(?<url>\S+)\s+link$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

        public static bool IsLinkOnlyText(string text)
        {
            Uri ignored;
            return TryGetLinkOnlyUri(text, out ignored);
        }

        public static bool TryGetLinkOnlyUri(string text, out Uri uri)
        {
            uri = null;
            var trimmed = (text ?? string.Empty).Trim();
            if (trimmed.Length == 0 || trimmed.IndexOfAny(new[] { '\r', '\n' }) >= 0) return false;
            var roleMatch = TrailingRolePattern.Match(trimmed);
            var candidate = roleMatch.Success ? roleMatch.Groups["url"].Value : trimmed;

            if (!Uri.TryCreate(candidate, UriKind.Absolute, out uri)) return false;
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
