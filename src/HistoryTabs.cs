using System;

namespace Clipman
{
    internal static class HistoryTabs
    {
        public const string Text = "Text";
        public const string Links = "Links";
        public const string Files = "Files";

        public static string Normalize(string value, bool linksEnabled)
        {
            var trimmed = (value ?? string.Empty).Trim();
            if (string.Equals(trimmed, Files, StringComparison.OrdinalIgnoreCase)) return Files;
            if (linksEnabled && string.Equals(trimmed, Links, StringComparison.OrdinalIgnoreCase)) return Links;
            return Text;
        }
    }
}
