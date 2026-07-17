using System;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Clipman
{
    internal static class ServerSettingsSanitizer
    {
        private static readonly Regex UrlRegex = new Regex(@"(?:https?|clipman)://[^\s""'<>]+", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex JsonAuthTokenRegex = new Regex(@"""AuthToken""\s*:\s*""([^""]+)""", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex JsonPortRegex = new Regex(@"""Port""\s*:\s*(\d+)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex JsonHostRegex = new Regex(@"""Host""\s*:\s*""([^""]+)""", RegexOptions.IgnoreCase | RegexOptions.Compiled);

        public static string CleanUrl(string value)
        {
            var text = (value ?? string.Empty).Trim();
            if (text.Length == 0) return string.Empty;

            var directUrl = UrlRegex.Match(text);
            if (directUrl.Success)
            {
                return NormalizeDisplayUrl(TrimUrlPunctuation(directUrl.Value));
            }

            var host = MatchGroup(JsonHostRegex, text);
            var port = MatchGroup(JsonPortRegex, text);
            if (host.Length > 0 && port.Length > 0)
            {
                if (string.Equals(host, "0.0.0.0", StringComparison.OrdinalIgnoreCase))
                {
                    host = "localhost";
                }
                return "clipman://" + host + ":" + port;
            }

            var cleaned = TrimUrlPunctuation(text);
            if (cleaned.Length > 0 &&
                cleaned.IndexOf("://", StringComparison.Ordinal) < 0 &&
                cleaned.IndexOfAny(new[] { ' ', '\t', '\r', '\n' }) < 0)
            {
                cleaned = "clipman://" + cleaned;
            }
            return NormalizeDisplayUrl(cleaned);
        }

        public static string CleanTransportUrl(string value)
        {
            var cleaned = CleanUrl(value);
            if (cleaned.StartsWith("clipman://", StringComparison.OrdinalIgnoreCase))
            {
                return "http://" + cleaned.Substring("clipman://".Length);
            }
            return cleaned;
        }

        public static string CleanToken(string value)
        {
            var text = (value ?? string.Empty).Trim();
            if (text.Length == 0) return string.Empty;

            var jsonToken = MatchGroup(JsonAuthTokenRegex, text);
            if (jsonToken.Length > 0)
            {
                return jsonToken.Trim();
            }

            try
            {
                var serializer = new JavaScriptSerializer();
                var parsed = serializer.Deserialize<ServerSettingsTokenProbe>(text);
                if (parsed != null && !string.IsNullOrWhiteSpace(parsed.AuthToken))
                {
                    return parsed.AuthToken.Trim();
                }
            }
            catch
            {
            }

            return text.Trim().Trim('"', '\'', ',', ';');
        }

        private static string MatchGroup(Regex regex, string text)
        {
            var match = regex.Match(text);
            return match.Success && match.Groups.Count > 1 ? match.Groups[1].Value.Trim() : string.Empty;
        }

        private static string TrimUrlPunctuation(string value)
        {
            return (value ?? string.Empty).Trim().Trim('"', '\'', ',', ';', '.', ')', ']', '}');
        }

        private static string NormalizeDisplayUrl(string value)
        {
            var cleaned = TrimUrlPunctuation(value);
            if (cleaned.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            {
                cleaned = "clipman://" + cleaned.Substring("http://".Length);
            }
            return cleaned;
        }

        private sealed class ServerSettingsTokenProbe
        {
            public string AuthToken { get; set; }
        }
    }
}
