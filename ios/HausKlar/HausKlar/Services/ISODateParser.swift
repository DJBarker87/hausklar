import Foundation

/// Shared ISO 8601 date parsing with fractional-seconds fallback.
///
/// Home Assistant returns timestamps with or without fractional seconds.
/// This utility tries `.withFractionalSeconds` first, then falls back
/// to `.withInternetDateTime` only, avoiding the need to create new
/// `ISO8601DateFormatter` instances on every call.
enum ISODateParser {
    /// Foundation formatters are mutable reference types and are not Sendable.
    /// One lock-protected store preserves their reuse without allowing
    /// concurrent mutation or paying formatter-construction cost per call.
    private final class FormatterStore: @unchecked Sendable {
        private let lock = NSLock()
        private let withFractional: ISO8601DateFormatter
        private let withoutFractional: ISO8601DateFormatter
        private let dateOnlyParser: DateFormatter
        private let utcDateOnlyFormatter: DateFormatter
        private let timeOnlyDisplay: DateFormatter
        private let timeWithSecondsDisplay: DateFormatter
        private let dateOnlyDisplay: DateFormatter
        private let dateTimeDisplay: DateFormatter
        private let enGBLongDateDisplay: DateFormatter
        private let relativeDisplay: RelativeDateTimeFormatter

        init() {
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.withFractional = withFractional

            let withoutFractional = ISO8601DateFormatter()
            withoutFractional.formatOptions = [.withInternetDateTime]
            self.withoutFractional = withoutFractional

            let dateOnlyParser = DateFormatter()
            dateOnlyParser.calendar = Calendar(identifier: .gregorian)
            dateOnlyParser.dateFormat = "yyyy-MM-dd"
            dateOnlyParser.locale = Locale(identifier: "en_US_POSIX")
            dateOnlyParser.timeZone = TimeZone.current
            self.dateOnlyParser = dateOnlyParser

            let utcDateOnlyFormatter = DateFormatter()
            utcDateOnlyFormatter.calendar = Calendar(identifier: .gregorian)
            utcDateOnlyFormatter.dateFormat = "yyyy-MM-dd"
            utcDateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
            utcDateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            self.utcDateOnlyFormatter = utcDateOnlyFormatter

            let timeOnlyDisplay = DateFormatter()
            timeOnlyDisplay.dateFormat = "HH:mm"
            self.timeOnlyDisplay = timeOnlyDisplay

            let timeWithSecondsDisplay = DateFormatter()
            timeWithSecondsDisplay.dateFormat = "HH:mm:ss"
            self.timeWithSecondsDisplay = timeWithSecondsDisplay

            let dateOnlyDisplay = DateFormatter()
            dateOnlyDisplay.dateStyle = .medium
            dateOnlyDisplay.timeStyle = .none
            self.dateOnlyDisplay = dateOnlyDisplay

            let dateTimeDisplay = DateFormatter()
            dateTimeDisplay.dateStyle = .medium
            dateTimeDisplay.timeStyle = .short
            self.dateTimeDisplay = dateTimeDisplay

            let enGBLongDateDisplay = DateFormatter()
            enGBLongDateDisplay.locale = Locale(identifier: "en_GB")
            enGBLongDateDisplay.dateFormat = "d MMMM yyyy"
            self.enGBLongDateDisplay = enGBLongDateDisplay

            let relativeDisplay = RelativeDateTimeFormatter()
            relativeDisplay.unitsStyle = .abbreviated
            self.relativeDisplay = relativeDisplay
        }

        func parse(_ string: String) -> Date? {
            lock.withLock {
                withFractional.date(from: string)
                    ?? withoutFractional.date(from: string)
                    ?? dateOnlyParser.date(from: string)
            }
        }

        func parseDateOnly(_ string: String) -> Date? {
            lock.withLock { dateOnlyParser.date(from: string) }
        }

        func dateOnlyString(from date: Date) -> String {
            lock.withLock { dateOnlyParser.string(from: date) }
        }

        func utcDateOnlyString(from date: Date) -> String {
            lock.withLock { utcDateOnlyFormatter.string(from: date) }
        }

        func parseUTCDateOnly(_ string: String) -> Date? {
            lock.withLock { utcDateOnlyFormatter.date(from: string) }
        }

        func string(from date: Date, fractional: Bool) -> String {
            lock.withLock {
                (fractional ? withFractional : withoutFractional).string(from: date)
            }
        }

        func timeOnly(from date: Date) -> String {
            lock.withLock { timeOnlyDisplay.string(from: date) }
        }

        func timeWithSeconds(from date: Date) -> String {
            lock.withLock { timeWithSecondsDisplay.string(from: date) }
        }

        func dateOnly(from date: Date) -> String {
            lock.withLock { dateOnlyDisplay.string(from: date) }
        }

        func dateTime(from date: Date) -> String {
            lock.withLock { dateTimeDisplay.string(from: date) }
        }

        func enGBLongDate(from date: Date) -> String {
            lock.withLock { enGBLongDateDisplay.string(from: date) }
        }

        func relative(from date: Date, relativeTo referenceDate: Date) -> String {
            lock.withLock { relativeDisplay.localizedString(for: date, relativeTo: referenceDate) }
        }
    }

    private static let formatters = FormatterStore()

    /// Parse an ISO 8601 string, trying fractional seconds first, then date-only.
    static func parse(_ string: String) -> Date? {
        formatters.parse(string)
    }

    /// Format a `Date` as an ISO 8601 string (with fractional seconds).
    static func string(from date: Date) -> String {
        formatters.string(from: date, fractional: true)
    }

    /// Format a `Date` as an ISO 8601 string (without fractional seconds).
    /// Matches the format expected by HA history API period endpoints.
    static func stringNoFractional(from date: Date) -> String {
        formatters.string(from: date, fractional: false)
    }

    /// Parse and format server date-only values in the user's current calendar
    /// timezone while retaining the shared formatter's serialized access.
    static func parseDateOnly(_ string: String) -> Date? {
        formatters.parseDateOnly(string)
    }

    static func stringDateOnly(from date: Date) -> String {
        formatters.dateOnlyString(from: date)
    }

    static func stringUTCDateOnly(from date: Date) -> String {
        formatters.utcDateOnlyString(from: date)
    }

    /// Parse a Gregorian `yyyy-MM-dd` value at UTC.
    static func parseUTCDateOnly(_ string: String) -> Date? {
        formatters.parseUTCDateOnly(string)
    }

    // MARK: - Shared Display Formatters

    static func timeOnly(from date: Date) -> String { formatters.timeOnly(from: date) }
    static func timeWithSeconds(from date: Date) -> String {
        formatters.timeWithSeconds(from: date)
    }
    static func dateOnly(from date: Date) -> String { formatters.dateOnly(from: date) }
    static func dateTime(from date: Date) -> String { formatters.dateTime(from: date) }
    static func enGBLongDate(from date: Date) -> String {
        formatters.enGBLongDate(from: date)
    }
    static func relative(from date: Date) -> String {
        formatters.relative(from: date, relativeTo: Date())
    }
}
