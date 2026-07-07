import Foundation
import ClipmanCore

enum TemplateResolver {
    struct TemplateItem {
        let name: String
        let text: String
    }

    static let presets: [TemplateItem] = [
        TemplateItem(name: "Date, year/month/day", text: "{{year_full}}/{{month_num_padded}}/{{day_of_month_padded}}"),
        TemplateItem(name: "Date, day short-month year", text: "{{day_of_month_padded}} {{month_name_short}} {{year_full}}"),
        TemplateItem(name: "Date, short-month day, year", text: "{{month_name_short}} {{day_of_month_padded}}, {{year_full}}"),
        TemplateItem(name: "Today sentence", text: "Today is {{day_name_full}}, {{month_name_full}} {{day_of_month}}, {{year_full}}"),
        TemplateItem(name: "Operating system version", text: "{{os_name}} version {{os_version}}")
    ]

    static let variables: [TemplateItem] = [
        TemplateItem(name: "Year, four digits", text: "{{year_full}}"),
        TemplateItem(name: "Year, two digits", text: "{{year_short}}"),
        TemplateItem(name: "Month name", text: "{{month_name_full}}"),
        TemplateItem(name: "Month name, short", text: "{{month_name_short}}"),
        TemplateItem(name: "Month number", text: "{{month_num}}"),
        TemplateItem(name: "Month number, two digits", text: "{{month_num_padded}}"),
        TemplateItem(name: "Day of month", text: "{{day_of_month}}"),
        TemplateItem(name: "Day of month, two digits", text: "{{day_of_month_padded}}"),
        TemplateItem(name: "Day name", text: "{{day_name_full}}"),
        TemplateItem(name: "Day name, short", text: "{{day_name_short}}"),
        TemplateItem(name: "Hour, 24-hour clock", text: "{{hour_24}}"),
        TemplateItem(name: "Hour, 24-hour clock, two digits", text: "{{hour_24_padded}}"),
        TemplateItem(name: "Hour, 12-hour clock", text: "{{hour_12}}"),
        TemplateItem(name: "Hour, 12-hour clock, two digits", text: "{{hour_12_padded}}"),
        TemplateItem(name: "Minute", text: "{{minute}}"),
        TemplateItem(name: "Minute, two digits", text: "{{minute_padded}}"),
        TemplateItem(name: "Second", text: "{{second}}"),
        TemplateItem(name: "Second, two digits", text: "{{second_padded}}"),
        TemplateItem(name: "UTC offset", text: "{{utc_offset}}"),
        TemplateItem(name: "Time zone", text: "{{time_zone}}"),
        TemplateItem(name: "Time zone, short", text: "{{time_zone_short}}"),
        TemplateItem(name: "Operating system name", text: "{{os_name}}"),
        TemplateItem(name: "Operating system version", text: "{{os_version}}"),
        TemplateItem(name: "User name", text: "{{username}}")
    ]

    static let variableReferenceText = """
    Template variables are resolved only when the entry is copied or pasted.

    Presets:
    Date, year/month/day - {{year_full}}/{{month_num_padded}}/{{day_of_month_padded}}
    Date, day short-month year - {{day_of_month_padded}} {{month_name_short}} {{year_full}}
    Date, short-month day, year - {{month_name_short}} {{day_of_month_padded}}, {{year_full}}
    Today sentence - Today is {{day_name_full}}, {{month_name_full}} {{day_of_month}}, {{year_full}}
    Operating system version - {{os_name}} version {{os_version}}

    Date and time:
    {{year_full}} - four-digit year
    {{year_short}} - two-digit year
    {{month_name}} - full month name
    {{month_name_full}} - full month name
    {{month_name_short}} - short month name
    {{month_num}} - month number
    {{month_num_padded}} - two-digit month number
    {{day_of_month}} - day of month
    {{day_of_month_padded}} - two-digit day of month
    {{day_name_full}} - full day name
    {{day_name_short}} - short day name
    {{hour_24}} - 24-hour clock hour
    {{hour_24_padded}} - two-digit 24-hour clock hour
    {{hour_12}} - 12-hour clock hour
    {{hour_12_padded}} - two-digit 12-hour clock hour
    {{minute}} - minute
    {{minute_padded}} - two-digit minute
    {{second}} - second
    {{second_padded}} - two-digit second
    {{utc_offset}} - local UTC offset
    {{time_zone}} - local time zone name
    {{time_zone_short}} - local time zone abbreviation

    System:
    {{os_name}} - operating system name
    {{os_version}} - operating system version
    {{username}} - current user name

    Examples:
    {{year_full}}-{{month_num_padded}}-{{day_of_month_padded}}
    Today is {{day_name_full}}, {{month_name_full}} {{day_of_month}}, {{year_full}}
    {{os_name}} version {{os_version}}
    """

    static func resolve(_ text: String) -> String {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\{\{([A-Za-z0-9_]+)\}\}"#) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let token = nsText.substring(with: match.range(at: 1))
            guard let value = resolveVariable(token) else { continue }
            if let range = Range(match.range(at: 0), in: result) {
                result.replaceSubrange(range, with: value)
            }
        }
        return result
    }

    static func resolveEntryText(_ entry: ClipEntry) -> String {
        entry.IsTemplate ? resolve(entry.Text) : entry.Text
    }

    private static func resolveVariable(_ name: String) -> String? {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch key {
        case "year_full": return String(format: "%04d", components.year ?? 0)
        case "year_short": return String(format: "%02d", (components.year ?? 0) % 100)
        case "month_name", "month_name_full":
            formatter.dateFormat = "MMMM"
            return formatter.string(from: now)
        case "month_name_short":
            formatter.dateFormat = "MMM"
            return formatter.string(from: now)
        case "month_num": return String(components.month ?? 0)
        case "month_num_padded": return String(format: "%02d", components.month ?? 0)
        case "day_of_month": return String(components.day ?? 0)
        case "day_of_month_padded": return String(format: "%02d", components.day ?? 0)
        case "day_name_full":
            formatter.dateFormat = "EEEE"
            return formatter.string(from: now)
        case "day_name_short":
            formatter.dateFormat = "EEE"
            return formatter.string(from: now)
        case "hour_24": return String(components.hour ?? 0)
        case "hour_24_padded": return String(format: "%02d", components.hour ?? 0)
        case "hour_12": return String(toTwelveHour(components.hour ?? 0))
        case "hour_12_padded": return String(format: "%02d", toTwelveHour(components.hour ?? 0))
        case "minute": return String(components.minute ?? 0)
        case "minute_padded": return String(format: "%02d", components.minute ?? 0)
        case "second": return String(components.second ?? 0)
        case "second_padded": return String(format: "%02d", components.second ?? 0)
        case "utc_offset": return utcOffsetText(TimeZone.current.secondsFromGMT(for: now))
        case "time_zone": return TimeZone.current.localizedName(for: .generic, locale: Locale.current) ?? TimeZone.current.identifier
        case "time_zone_short": return TimeZone.current.abbreviation(for: now) ?? ""
        case "os_name": return "macOS"
        case "os_version": return ProcessInfo.processInfo.operatingSystemVersionString
        case "username": return NSUserName()
        default: return nil
        }
    }

    private static func toTwelveHour(_ hour: Int) -> Int {
        let value = hour % 12
        return value == 0 ? 12 : value
    }

    private static func utcOffsetText(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return "\(sign)\(hours):\(String(format: "%02d", minutes))"
    }
}
