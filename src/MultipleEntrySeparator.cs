using System;

namespace Clipman
{
    internal static class MultipleEntrySeparator
    {
        public static string NormalizeMode(string value)
        {
            switch ((value ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "NONE": return "None";
                case "NEWLINE": return "NewLine";
                case "SPACE": return "Space";
                case "COMMASPACE": return "CommaSpace";
                case "CUSTOM": return "Custom";
                case "BLANKLINE":
                default: return "BlankLine";
            }
        }

        public static string Resolve(string mode, string custom)
        {
            switch (NormalizeMode(mode))
            {
                case "None": return string.Empty;
                case "NewLine": return Environment.NewLine;
                case "Space": return " ";
                case "CommaSpace": return ", ";
                case "Custom": return DecodeCustom(custom);
                default: return Environment.NewLine + Environment.NewLine;
            }
        }

        private static string DecodeCustom(string value)
        {
            return (value ?? string.Empty)
                .Replace("\\r\\n", "\r\n")
                .Replace("\\n", "\n")
                .Replace("\\r", "\r")
                .Replace("\\t", "\t");
        }
    }
}
