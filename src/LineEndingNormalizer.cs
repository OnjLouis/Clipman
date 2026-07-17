namespace Clipman
{
    internal static class LineEndingNormalizer
    {
        public const string Windows = "\r\n";
        public const string Unix = "\n";
        public const string OldMac = "\r";

        public static string ToWindows(string text)
        {
            return Normalize(text, Windows);
        }

        public static string ToUnix(string text)
        {
            return Normalize(text, Unix);
        }

        public static string ToOldMac(string text)
        {
            return Normalize(text, OldMac);
        }

        public static string Normalize(string text, string targetLineEnding)
        {
            if (text == null) return string.Empty;
            if (string.IsNullOrEmpty(targetLineEnding)) targetLineEnding = Windows;

            return text
                .Replace("\r\n", "\n")
                .Replace("\r", "\n")
                .Replace("\u0085", "\n")
                .Replace("\u2028", "\n")
                .Replace("\u2029", "\n")
                .Replace("\n", targetLineEnding);
        }
    }
}
