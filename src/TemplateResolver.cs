using System;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;

namespace Clipman
{
    internal static class TemplateResolver
    {
        private static readonly Regex VariablePattern = new Regex(@"\{\{([A-Za-z0-9_]+)\}\}", RegexOptions.Compiled);

        public sealed class TemplateItem
        {
            public string Name { get; private set; }
            public string Text { get; private set; }

            public TemplateItem(string name, string text)
            {
                Name = name ?? string.Empty;
                Text = text ?? string.Empty;
            }

            public override string ToString()
            {
                return Name;
            }
        }

        public static readonly TemplateItem[] Presets =
        {
            new TemplateItem("Date, year/month/day", "{{year_full}}/{{month_num_padded}}/{{day_of_month_padded}}"),
            new TemplateItem("Date, day short-month year", "{{day_of_month_padded}} {{month_name_short}} {{year_full}}"),
            new TemplateItem("Date, short-month day, year", "{{month_name_short}} {{day_of_month_padded}}, {{year_full}}"),
            new TemplateItem("Today sentence", "Today is {{day_name_full}}, {{month_name_full}} {{day_of_month}}, {{year_full}}"),
            new TemplateItem("Operating system version", "{{os_name}} version {{os_version}}")
        };

        public static readonly TemplateItem[] Variables =
        {
            new TemplateItem("Year, four digits", "{{year_full}}"),
            new TemplateItem("Year, two digits", "{{year_short}}"),
            new TemplateItem("Month name", "{{month_name_full}}"),
            new TemplateItem("Month name, short", "{{month_name_short}}"),
            new TemplateItem("Month number", "{{month_num}}"),
            new TemplateItem("Month number, two digits", "{{month_num_padded}}"),
            new TemplateItem("Day of month", "{{day_of_month}}"),
            new TemplateItem("Day of month, two digits", "{{day_of_month_padded}}"),
            new TemplateItem("Day name", "{{day_name_full}}"),
            new TemplateItem("Day name, short", "{{day_name_short}}"),
            new TemplateItem("Hour, 24-hour clock", "{{hour_24}}"),
            new TemplateItem("Hour, 24-hour clock, two digits", "{{hour_24_padded}}"),
            new TemplateItem("Hour, 12-hour clock", "{{hour_12}}"),
            new TemplateItem("Hour, 12-hour clock, two digits", "{{hour_12_padded}}"),
            new TemplateItem("Minute", "{{minute}}"),
            new TemplateItem("Minute, two digits", "{{minute_padded}}"),
            new TemplateItem("Second", "{{second}}"),
            new TemplateItem("Second, two digits", "{{second_padded}}"),
            new TemplateItem("UTC offset", "{{utc_offset}}"),
            new TemplateItem("Time zone", "{{time_zone}}"),
            new TemplateItem("Time zone, short", "{{time_zone_short}}"),
            new TemplateItem("Operating system name", "{{os_name}}"),
            new TemplateItem("Operating system version", "{{os_version}}"),
            new TemplateItem("User name", "{{username}}")
        };

        public static readonly string VariableReferenceText =
            "Template variables are resolved only when the entry is copied or pasted.\r\n\r\n" +
            "Presets:\r\n" +
            string.Join("\r\n", Presets.Select(p => p.Name + " - " + p.Text).ToArray()) +
            "\r\n\r\n" +
            "Date and time:\r\n" +
            "{{year_full}} - four-digit year\r\n" +
            "{{year_short}} - two-digit year\r\n" +
            "{{month_name}} - full month name\r\n" +
            "{{month_name_full}} - full month name\r\n" +
            "{{month_name_short}} - short month name\r\n" +
            "{{month_num}} - month number\r\n" +
            "{{month_num_padded}} - two-digit month number\r\n" +
            "{{day_of_month}} - day of month\r\n" +
            "{{day_of_month_padded}} - two-digit day of month\r\n" +
            "{{day_name_full}} - full day name\r\n" +
            "{{day_name_short}} - short day name\r\n" +
            "{{hour_24}} - 24-hour clock hour\r\n" +
            "{{hour_24_padded}} - two-digit 24-hour clock hour\r\n" +
            "{{hour_12}} - 12-hour clock hour\r\n" +
            "{{hour_12_padded}} - two-digit 12-hour clock hour\r\n" +
            "{{minute}} - minute\r\n" +
            "{{minute_padded}} - two-digit minute\r\n" +
            "{{second}} - second\r\n" +
            "{{second_padded}} - two-digit second\r\n" +
            "{{utc_offset}} - local UTC offset\r\n" +
            "{{time_zone}} - local time zone name\r\n" +
            "{{time_zone_short}} - local time zone abbreviation\r\n\r\n" +
            "System:\r\n" +
            "{{os_name}} - operating system name\r\n" +
            "{{os_version}} - operating system version\r\n" +
            "{{username}} - current user name\r\n\r\n" +
            "Examples:\r\n" +
            "{{year_full}}-{{month_num_padded}}-{{day_of_month_padded}}\r\n" +
            "Today is {{day_name_full}}, {{month_name_full}} {{day_of_month}}, {{year_full}}\r\n" +
            "{{os_name}} version {{os_version}}";

        public static string Resolve(string text)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;
            var now = DateTime.Now;
            var culture = CultureInfo.CurrentCulture;
            return VariablePattern.Replace(text, match =>
            {
                var name = match.Groups[1].Value;
                var value = ResolveVariable(name, now, culture);
                return value == null ? match.Value : value;
            });
        }

        private static string ResolveVariable(string name, DateTime now, CultureInfo culture)
        {
            switch ((name ?? string.Empty).Trim().ToLowerInvariant())
            {
                case "year_full": return now.ToString("yyyy", culture);
                case "year_short": return now.ToString("yy", culture);
                case "month_name":
                case "month_name_full": return culture.DateTimeFormat.GetMonthName(now.Month);
                case "month_name_short": return culture.DateTimeFormat.GetAbbreviatedMonthName(now.Month);
                case "month_num": return now.Month.ToString(culture);
                case "month_num_padded": return now.Month.ToString("00", culture);
                case "day_of_month": return now.Day.ToString(culture);
                case "day_of_month_padded": return now.Day.ToString("00", culture);
                case "day_name_full": return culture.DateTimeFormat.GetDayName(now.DayOfWeek);
                case "day_name_short": return culture.DateTimeFormat.GetAbbreviatedDayName(now.DayOfWeek);
                case "hour_24": return now.Hour.ToString(culture);
                case "hour_24_padded": return now.Hour.ToString("00", culture);
                case "hour_12": return ToTwelveHour(now.Hour).ToString(culture);
                case "hour_12_padded": return ToTwelveHour(now.Hour).ToString("00", culture);
                case "minute": return now.Minute.ToString(culture);
                case "minute_padded": return now.Minute.ToString("00", culture);
                case "second": return now.Second.ToString(culture);
                case "second_padded": return now.Second.ToString("00", culture);
                case "utc_offset": return UtcOffsetText(TimeZoneInfo.Local.GetUtcOffset(now));
                case "time_zone": return TimeZoneName(now);
                case "time_zone_short": return TimeZoneShortName(TimeZoneName(now));
                case "os_name": return "Windows";
                case "os_version": return Environment.OSVersion.VersionString;
                case "username": return Environment.UserName;
                default: return null;
            }
        }

        private static int ToTwelveHour(int hour)
        {
            var value = hour % 12;
            return value == 0 ? 12 : value;
        }

        private static string UtcOffsetText(TimeSpan offset)
        {
            var sign = offset < TimeSpan.Zero ? "-" : "+";
            offset = offset.Duration();
            return sign + ((int)offset.TotalHours).ToString(CultureInfo.InvariantCulture) + ":" + offset.Minutes.ToString("00", CultureInfo.InvariantCulture);
        }

        private static string TimeZoneName(DateTime now)
        {
            return TimeZoneInfo.Local.IsDaylightSavingTime(now)
                ? TimeZoneInfo.Local.DaylightName
                : TimeZoneInfo.Local.StandardName;
        }

        private static string TimeZoneShortName(string name)
        {
            if (string.IsNullOrWhiteSpace(name)) return string.Empty;
            var letters = name
                .Split(new[] { ' ', '-', '_' }, StringSplitOptions.RemoveEmptyEntries)
                .Where(part => part.Length > 0)
                .Select(part => char.ToUpperInvariant(part[0]))
                .ToArray();
            return letters.Length == 0 ? name : new string(letters);
        }
    }
}
