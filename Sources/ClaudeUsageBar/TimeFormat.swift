import Foundation

// The panel's text is English, so the clock text is English too ("3:09 PM", not
// "오후 3:09"). The 12- or 24-hour choice still follows the Mac's setting, which
// is what "j" resolves to in the current locale.
enum TimeFormat {
    static func clock(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = uses24HourClock(locale) ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    static func uses24HourClock(_ locale: Locale) -> Bool {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h"
        return !template.contains("h") && !template.contains("K")
    }
}
