using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace Clipman
{
    internal static class UrlTrackingCleaner
    {
        private static readonly Regex HtmlUrlAttributeRegex = new Regex(
            @"(?<prefix>\b(?:href|src|action)\s*=\s*[""'])(?<url>https?://[^""']+)(?<suffix>[""'])",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        private static readonly Regex PlainUrlRegex = new Regex(
            @"https?://[^\s<>'""]+",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        private static readonly HashSet<string> TrackingParameters = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "fbclid",
            "gclid",
            "dclid",
            "msclkid",
            "gbraid",
            "wbraid",
            "igshid",
            "mc_cid",
            "mc_eid",
            "mkt_tok",
            "vero_id",
            "_hsenc",
            "_hsmi",
            "yclid",
            "twclid",
            "li_fat_id",
            "sc_cid",
            "oly_anon_id",
            "oly_enc_id",
            "rb_clickid",
            "spm",
            "ref",
            "ref_src"
        };

        public static string CleanText(string text)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;

            var cleaned = HtmlUrlAttributeRegex.Replace(text, match =>
            {
                var url = match.Groups["url"].Value;
                var cleanedUrl = CleanUrl(url, true);
                return match.Groups["prefix"].Value + cleanedUrl + match.Groups["suffix"].Value;
            });

            cleaned = PlainUrlRegex.Replace(cleaned, match =>
            {
                var value = match.Value;
                var trailing = string.Empty;
                while (value.Length > 0 && ".,);]!?".IndexOf(value[value.Length - 1]) >= 0)
                {
                    trailing = value[value.Length - 1] + trailing;
                    value = value.Substring(0, value.Length - 1);
                }

                return CleanUrl(value, false) + trailing;
            });

            return cleaned;
        }

        private static string CleanUrl(string url, bool htmlAttribute)
        {
            if (string.IsNullOrWhiteSpace(url)) return url ?? string.Empty;

            var parseUrl = htmlAttribute ? DecodeHtmlAmpersands(url) : url;
            Uri uri;
            if (!Uri.TryCreate(parseUrl, UriKind.Absolute, out uri))
            {
                return url;
            }
            if (!string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            {
                return url;
            }

            var query = uri.Query;
            if (string.IsNullOrEmpty(query) || query == "?") return url;
            var parts = query.TrimStart('?').Split(new[] { '&' }, StringSplitOptions.RemoveEmptyEntries);
            var kept = new List<string>();
            var changed = false;
            foreach (var part in parts)
            {
                var equals = part.IndexOf('=');
                var name = equals >= 0 ? part.Substring(0, equals) : part;
                if (ShouldRemoveParameter(name))
                {
                    changed = true;
                    continue;
                }
                kept.Add(part);
            }

            if (!changed) return url;

            var builder = new UriBuilder(uri)
            {
                Query = kept.Count == 0 ? string.Empty : string.Join("&", kept.ToArray())
            };
            var result = builder.Uri.ToString();
            return htmlAttribute ? EncodeHtmlAmpersands(result) : result;
        }

        private static bool ShouldRemoveParameter(string name)
        {
            if (string.IsNullOrWhiteSpace(name)) return false;
            var decoded = Uri.UnescapeDataString(name).Trim();
            if (decoded.StartsWith("utm_", StringComparison.OrdinalIgnoreCase)) return true;
            if (decoded.StartsWith("hsa_", StringComparison.OrdinalIgnoreCase)) return true;
            return TrackingParameters.Contains(decoded);
        }

        private static string DecodeHtmlAmpersands(string value)
        {
            return value.Replace("&amp;", "&").Replace("&#38;", "&").Replace("&#x26;", "&").Replace("&#X26;", "&");
        }

        private static string EncodeHtmlAmpersands(string value)
        {
            return value.Replace("&", "&amp;");
        }
    }
}
