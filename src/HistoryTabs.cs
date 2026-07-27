using System;
using System.Collections.Generic;
using System.Linq;

namespace Clipman
{
    internal static class HistoryTabs
    {
        public const string Text = "Text";
        public const string Links = "Links";
        public const string RichText = "RichText";
        public const string Files = "Files";

        public static List<string> DefaultOrder()
        {
            return new List<string> { Text, Links, RichText, Files };
        }

        public static List<string> NormalizeOrder(IEnumerable<string> values)
        {
            var normalized = new List<string>();
            foreach (var value in values ?? Enumerable.Empty<string>())
            {
                var canonical = Canonical(value);
                if (canonical != null && !normalized.Contains(canonical, StringComparer.OrdinalIgnoreCase))
                {
                    normalized.Add(canonical);
                }
            }
            foreach (var tab in DefaultOrder())
            {
                if (!normalized.Contains(tab, StringComparer.OrdinalIgnoreCase)) normalized.Add(tab);
            }
            return normalized;
        }

        public static List<string> VisibleOrder(IEnumerable<string> values, bool linksEnabled, bool richTextEnabled)
        {
            return NormalizeOrder(values).Where(tab =>
                !string.Equals(tab, Links, StringComparison.OrdinalIgnoreCase) || linksEnabled)
                .Where(tab => !string.Equals(tab, RichText, StringComparison.OrdinalIgnoreCase) || richTextEnabled)
                .ToList();
        }

        public static bool TryMoveVisible(IEnumerable<string> values, string selected, int direction, bool linksEnabled, bool richTextEnabled, out List<string> moved)
        {
            moved = NormalizeOrder(values);
            var visible = VisibleOrder(moved, linksEnabled, richTextEnabled);
            var selectedIndex = visible.FindIndex(tab => string.Equals(tab, selected, StringComparison.OrdinalIgnoreCase));
            var targetIndex = selectedIndex + Math.Sign(direction);
            if (selectedIndex < 0 || direction == 0 || targetIndex < 0 || targetIndex >= visible.Count) return false;
            var first = moved.FindIndex(tab => string.Equals(tab, visible[selectedIndex], StringComparison.OrdinalIgnoreCase));
            var second = moved.FindIndex(tab => string.Equals(tab, visible[targetIndex], StringComparison.OrdinalIgnoreCase));
            var temporary = moved[first];
            moved[first] = moved[second];
            moved[second] = temporary;
            return true;
        }

        public static string Normalize(string value, bool linksEnabled, bool richTextEnabled)
        {
            var trimmed = (value ?? string.Empty).Trim();
            if (string.Equals(trimmed, Files, StringComparison.OrdinalIgnoreCase)) return Files;
            if (linksEnabled && string.Equals(trimmed, Links, StringComparison.OrdinalIgnoreCase)) return Links;
            if (richTextEnabled && string.Equals(trimmed, RichText, StringComparison.OrdinalIgnoreCase)) return RichText;
            return Text;
        }

        private static string Canonical(string value)
        {
            var trimmed = (value ?? string.Empty).Trim();
            if (string.Equals(trimmed, Text, StringComparison.OrdinalIgnoreCase)) return Text;
            if (string.Equals(trimmed, Links, StringComparison.OrdinalIgnoreCase)) return Links;
            if (string.Equals(trimmed, RichText, StringComparison.OrdinalIgnoreCase)) return RichText;
            if (string.Equals(trimmed, Files, StringComparison.OrdinalIgnoreCase)) return Files;
            return null;
        }
    }
}
