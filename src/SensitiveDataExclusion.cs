using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Clipman
{
    internal sealed class SensitiveDataPreset
    {
        public string Id { get; private set; }
        public string Name { get; private set; }
        public string Pattern { get; private set; }
        public bool SeparatorsOptional { get; private set; }
        public bool RequireLuhn { get; private set; }

        public SensitiveDataPreset(string id, string name, string pattern, bool separatorsOptional, bool requireLuhn)
        {
            Id = id ?? string.Empty;
            Name = name ?? string.Empty;
            Pattern = pattern ?? string.Empty;
            SeparatorsOptional = separatorsOptional;
            RequireLuhn = requireLuhn;
        }

        public override string ToString()
        {
            return Name;
        }
    }

    internal sealed class SensitiveDataMatch
    {
        public string PresetName { get; private set; }

        public SensitiveDataMatch(string presetName)
        {
            PresetName = presetName ?? string.Empty;
        }
    }

    internal static class SensitiveDataExclusion
    {
        public const string ModeOff = "Off";
        public const string ModeExclude = "Exclude";

        public static readonly SensitiveDataPreset[] BuiltInPresets =
        {
            new SensitiveDataPreset("credit-card", "Credit card number", "#{13,19}", true, true),
            new SensitiveDataPreset("us-ssn", "US Social Security number", "###-##-####", true, false),
            new SensitiveDataPreset("international-phone", "International phone number", "+###########", true, false),
            new SensitiveDataPreset("api-token", "Long API key or token", "*{32,}", false, false),
            new SensitiveDataPreset("software-license-key", "Software license key", "*{5}-*{5}-*{5}-*{5}-*{5}", false, false),
            new SensitiveDataPreset("us-drivers-license", "US driver license, approximate", "@#{6,13}", false, false)
        };

        public static bool IsEnabled(AppSettings settings)
        {
            return settings != null &&
                string.Equals(settings.SensitiveDataMode, ModeExclude, StringComparison.OrdinalIgnoreCase) &&
                settings.SensitiveDataPresetIds != null &&
                settings.SensitiveDataPresetIds.Count > 0;
        }

        public static SensitiveDataMatch FindMatch(string text, AppSettings settings)
        {
            if (string.IsNullOrEmpty(text) || !IsEnabled(settings)) return null;
            if (IsFullHttpUrl(text)) return null;
            var enabled = new HashSet<string>(settings.SensitiveDataPresetIds, StringComparer.OrdinalIgnoreCase);
            foreach (var preset in BuiltInPresets.Where(p => enabled.Contains(p.Id)))
            {
                if (MatchesPreset(text, preset))
                {
                    return new SensitiveDataMatch(preset.Name);
                }
            }

            return null;
        }

        public static string NormalizeMode(string mode)
        {
            return string.Equals(mode, ModeExclude, StringComparison.OrdinalIgnoreCase) ? ModeExclude : ModeOff;
        }

        private static bool MatchesPreset(string text, SensitiveDataPreset preset)
        {
            if (string.Equals(preset.Id, "international-phone", StringComparison.OrdinalIgnoreCase))
            {
                return MatchesInternationalPhone(text);
            }

            Regex regex;
            try
            {
                regex = new Regex(CompilePattern(preset.Pattern, preset.SeparatorsOptional), RegexOptions.CultureInvariant);
            }
            catch
            {
                return false;
            }

            foreach (Match match in regex.Matches(text))
            {
                if (!match.Success) continue;
                if (!preset.RequireLuhn || PassesLuhn(match.Value))
                {
                    return true;
                }
            }

            return false;
        }

        private static bool IsFullHttpUrl(string text)
        {
            var trimmed = (text ?? string.Empty).Trim();
            if (trimmed.Length == 0 || trimmed.Any(char.IsWhiteSpace)) return false;
            Uri uri;
            return Uri.TryCreate(trimmed, UriKind.Absolute, out uri) &&
                (string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase));
        }

        private static bool MatchesInternationalPhone(string text)
        {
            foreach (Match match in Regex.Matches(text ?? string.Empty, @"(?<![A-Za-z0-9])\+[\d][\d\s().-]{6,20}\d(?![A-Za-z0-9])", RegexOptions.CultureInvariant))
            {
                var digits = new string(match.Value.Where(char.IsDigit).ToArray());
                if (digits.Length >= 8 && digits.Length <= 15)
                {
                    return true;
                }
            }

            return false;
        }

        private static string CompilePattern(string pattern, bool separatorsOptional)
        {
            var output = new StringBuilder();
            output.Append(@"(?<![A-Za-z0-9])");
            for (var i = 0; i < pattern.Length; i++)
            {
                var current = pattern[i];
                if (current == '#' || current == '@' || current == '*' || current == '.')
                {
                    var tokenRegex = TokenRegex(current);
                    if (i + 1 < pattern.Length && pattern[i + 1] == '{')
                    {
                        var end = pattern.IndexOf('}', i + 2);
                        var quantifier = end > i ? pattern.Substring(i + 1, end - i) : string.Empty;
                        int min;
                        int? max;
                        if (TryParseQuantifier(quantifier, out min, out max))
                        {
                            output.Append(QuantifiedTokenRegex(tokenRegex, min, max, separatorsOptional));
                            i = end;
                            continue;
                        }
                    }
                    output.Append(tokenRegex);
                    if (separatorsOptional)
                    {
                        output.Append(@"[ -]?");
                    }
                    continue;
                }

                if (char.IsWhiteSpace(current))
                {
                    output.Append(separatorsOptional ? @"[ -]?" : @"\s+");
                    continue;
                }

                output.Append(Regex.Escape(current.ToString()));
            }
            output.Append(@"(?![A-Za-z0-9])");
            return output.ToString();
        }

        private static string QuantifiedTokenRegex(string tokenRegex, int min, int? max, bool separatorsOptional)
        {
            if (!separatorsOptional)
            {
                return tokenRegex + "{" + min.ToString() + (max.HasValue ? "," + max.Value.ToString() : ",") + "}";
            }

            if (min <= 1)
            {
                var suffix = max.HasValue ? "{0," + Math.Max(0, max.Value - 1).ToString() + "}" : "*";
                return tokenRegex + "(?:[ -]?" + tokenRegex + ")" + suffix;
            }

            var repeatMin = min - 1;
            var repeatMax = max.HasValue ? Math.Max(0, max.Value - 1).ToString() : string.Empty;
            return tokenRegex + "(?:[ -]?" + tokenRegex + "){" + repeatMin.ToString() + "," + repeatMax + "}";
        }

        private static string TokenRegex(char token)
        {
            switch (token)
            {
                case '#': return @"\d";
                case '@': return @"[A-Za-z]";
                case '*': return @"[A-Za-z0-9]";
                case '.': return @".";
                default: return Regex.Escape(token.ToString());
            }
        }

        private static bool TryParseQuantifier(string text, out int min, out int? max)
        {
            min = 0;
            max = null;
            var match = Regex.Match(text ?? string.Empty, @"^\{(\d+)(?:[,-](\d*))?\}$");
            if (!match.Success) return false;
            if (!int.TryParse(match.Groups[1].Value, out min)) return false;
            if (match.Groups[2].Success && match.Groups[2].Value.Length > 0)
            {
                int parsedMax;
                if (!int.TryParse(match.Groups[2].Value, out parsedMax)) return false;
                if (parsedMax < min) return false;
                max = parsedMax;
            }
            else if (!text.Contains(",") && !text.Contains("-"))
            {
                max = min;
            }
            return min > 0;
        }

        private static bool PassesLuhn(string text)
        {
            var digits = new string((text ?? string.Empty).Where(char.IsDigit).ToArray());
            if (digits.Length < 13 || digits.Length > 19) return false;
            var sum = 0;
            var doubleDigit = false;
            for (var i = digits.Length - 1; i >= 0; i--)
            {
                var value = digits[i] - '0';
                if (doubleDigit)
                {
                    value *= 2;
                    if (value > 9) value -= 9;
                }
                sum += value;
                doubleDigit = !doubleDigit;
            }
            return sum % 10 == 0;
        }
    }
}
