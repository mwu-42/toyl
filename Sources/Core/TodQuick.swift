// Copied from Oyl (Sources/TodQuick.swift) unchanged, so a date typed into toyl means what it
// means in Oyl's notch and in tod. Keep the two in step.

import Foundation

/// What a line typed into the to-do field means: "essay #cs fri 5pm" is a task called "essay" for
/// the cs list, due this Friday at 5 PM. Dates and times are read just as tod's quick add reads
/// them (its `public/nlp.js`, ported rule for rule), so a task means the same in either app. The
/// #list is Oyl's own: tod has no tags.
struct TodQuick: Equatable {
    let title: String
    let due: String?      // "YYYY-MM-DD"
    let time: String?     // "HH:MM"
    let list: String?     // the #tag as typed, without "#", if any (the first one)

    /// Every #tag comes out of the title and the first picks the list; the rest is read the way
    /// tod reads it. The title is empty only if there was nothing but tags.
    static func parse(_ input: String, now: Date = Date(), weekStart: Int = 1) -> TodQuick {
        let whole = NSRange(location: 0, length: (input as NSString).length)
        let tag = tagPattern.firstMatch(in: input, range: whole).map { (input as NSString).substring(with: $0.range(at: 1)) }
        let text = tagPattern.stringByReplacingMatches(in: input, range: whole, withTemplate: " ")
        let parsed = read(text, now: now, weekStart: weekStart)
        return TodQuick(title: parsed.title, due: parsed.due, time: parsed.time, list: tag)
    }

    /// The list a tag files into: exact name, then a word of the name starting with it, then the
    /// name without spaces containing it (emoji, punctuation, case and accents ignored: "#math" →
    /// "🤓 math 61cm", "#106b"/"#cs" → "💻 cs 106b"). The first in `lists` wins a tie. Nil if none
    /// matches (the caller makes a new list named after the tag).
    static func list(for tag: String, among lists: [(id: String, name: String)]) -> String? {
        let key = words(tag).joined()
        guard !key.isEmpty else { return nil }
        let named = lists.map { (id: $0.id, words: words($0.name)) }
        return named.first { $0.words.joined() == key }?.id
            ?? named.first { $0.words.contains { $0.hasPrefix(key) } }?.id
            ?? named.first { $0.words.joined().contains(key) }?.id
    }

    /// "Today", "Tomorrow", "Yesterday", "Fri" within the week, else "Oct 30" ("Oct 30, 2027" in
    /// another year): tod's `describeDate`, for showing a due date.
    static func describe(due: String, now: Date = Date()) -> String {
        let parts = due.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2] else { return due }
        let date = Day(year, month - 1, day)
        let today = Day(now)
        switch date.number - today.number {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return weekdayName.string(from: date.noon)
        default: return (year == today.year ? monthDay : monthDayYear).string(from: date.noon)
        }
    }

    /// "5 PM", or "5:30 PM" (tod's `fmtTime`), in the Mac's own way of writing times.
    static func describe(time: String) -> String {
        let parts = time.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1],
              let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute))
        else { return time }
        // A plain space before "PM", as tod shows it, where macOS puts a narrow one.
        return (minute == 0 ? hourOnly : hourAndMinute).string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: - tags

    /// "#" and then letters, digits, "-" or "_", with at least one letter or digit, and not inside
    /// a word or a link: "c#", "page#top" and "site/#/x" aren't tags.
    static let tagPattern = pattern(#"(?<![\p{L}\p{M}\p{N}_#/&])#([\p{L}\p{M}\p{N}_\-]*[\p{L}\p{N}][\p{L}\p{M}\p{N}_\-]*)"#)

    /// A name's words, lowercased with accents dropped, and emoji and punctuation left out.
    static func words(_ name: String) -> [String] {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    // MARK: - tod's parseQuick

    /// tod's `parseQuick`, step for step, quirks and all (months roll over like JavaScript's, so
    /// "in 1 month" from Jan 31 is early March, and "the 5th" late in December finds nothing),
    /// since meaning what tod means is the point.
    static func read(_ input: String, now: Date, weekStart: Int) -> (title: String, due: String?, time: String?) {
        var s = replacing(spaceRuns, in: input, with: " ")
        var due: String?
        var time: String?
        var weekdayToday = false
        // Down to the second (tod's clock counts whole milliseconds), so a moment just before the
        // minute turns isn't rounded into the next one.
        let now = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        let today = Day(now)
        let nowHM = pad(clock.hour!) + ":" + pad(clock.minute!)

        // Runs each pattern in turn; the first that matches (and whose handler doesn't turn it
        // down) is taken out of the text. Patterns are matched against the text with A–Z
        // lowered, the only case JavaScript ignores, which also lowers what the handlers see.
        func first(_ rules: [(NSRegularExpression, (Groups) -> Bool)]) {
            let lowered = asciiLowercased(s)
            let whole = NSRange(location: 0, length: (lowered as NSString).length)
            for (pattern, take) in rules {
                if let match = pattern.firstMatch(in: lowered, range: whole), take(Groups(match: match, text: lowered as NSString)) {
                    s = (s as NSString).replacingCharacters(in: match.range, with: " ")
                    return
                }
            }
        }
        func setTime(_ hour: Int, _ minute: Int) -> Bool {
            guard (0...23).contains(hour), (0...59).contains(minute) else { return false }
            time = pad(hour) + ":" + pad(minute)
            return true
        }
        func setDate(_ day: Day?) -> Bool {
            guard let day else { return false }
            due = day.text
            return true
        }
        func upcoming(_ weekday: Int, includingToday: Bool) -> Day {
            let ahead = (weekday - today.weekday + 7) % 7
            return today.adding(ahead == 0 && !includingToday ? 7 : ahead)
        }
        func startOfNextWeek() -> Day {
            let ahead = (weekStart - today.weekday + 7) % 7
            return today.adding(ahead == 0 ? 7 : ahead)
        }
        // A month and day without a year: this year, unless that was over a month ago.
        func withYear(_ month: Int, _ day: Int, _ year: Int) -> Day? {
            if year != 0 { return validDay(year, month, day) }
            guard let date = validDay(today.year, month, day) else { return nil }
            return date.adding(30) < today ? validDay(today.year + 1, month, day) : date
        }

        // times
        first([
            (hourRange, { m in
                let h1 = m.number(1), h2 = m.number(4)
                guard (1...12).contains(h1), (1...12).contains(h2) else { return false }
                let end = hour12(h2, m[6]!)
                var start: Int
                if let meridiem = m[3] {
                    start = hour12(h1, meridiem)
                } else {
                    // "11-1pm" starts in the morning.
                    start = hour12(h1, m[6]!)
                    if start * 60 + m.number(2) > end * 60 + m.number(5) { start = hour12(h1, m[6]!.hasPrefix("p") ? "am" : "pm") }
                }
                return setTime(start, m.number(2))
            }),
            (hourWithMeridiem, { m in
                let hour = m.number(1)
                guard (1...12).contains(hour) else { return false }
                return setTime(hour12(hour, m[3] ?? m[4]!), m.number(2))
            }),
            (clockTime, { m in
                let hour = m.number(1)
                guard hour <= 23 else { return false }
                return setTime(m[1]!.count == 1 ? guessHour(hour) : hour, m.number(2))
            }),
            (noonOrMidnight, { m in setTime(m[1] == "midnight" ? 0 : 12, 0) }),
            (inHours, { m in
                let n = count(m[1]!)
                let minutes = m[2]!.hasPrefix("h") ? n * 60 : n
                guard minutes != 0, minutes <= 60 * 24 * 3 else { return false }
                // Then up to a whole five minutes, seconds dropped, on the clock (as JavaScript's
                // setMinutes does, which matters on the nights the clocks change).
                let later = now.addingTimeInterval(TimeInterval(minutes * 60))
                let parts = calendar.dateComponents([.hour, .minute], from: later)
                let into = parts.hour! * 60 + (parts.minute! + 4) / 5 * 5    // minutes into the day, up to 24:00
                let day = Day(later).adding(into / (24 * 60))
                guard let rounded = calendar.date(from: DateComponents(year: day.year, month: day.month + 1, day: day.day,
                                                                       hour: into % (24 * 60) / 60, minute: into % 60))
                else { return false }
                let then = calendar.dateComponents([.hour, .minute], from: rounded)
                due = Day(rounded).text
                return setTime(then.hour!, then.minute!)
            }),
            (atHour, { m in
                let hour = m.number(1)
                guard hour <= 23 else { return false }
                return setTime(guessHour(hour), 0)
            }),
        ])

        // dates (skipped if "in 2 hours" already set one)
        if due == nil {
            first([
                (todayWord, { _ in setDate(today) }),
                (dayAfterTomorrow, { _ in setDate(today.adding(2)) }),
                (tomorrowWord, { _ in setDate(today.adding(1)) }),
                (nextWeekend, { _ in setDate(upcoming(6, includingToday: true).adding(7)) }),
                (weekend, { _ in setDate(upcoming(6, includingToday: true)) }),
                (nextWeek, { _ in setDate(startOfNextWeek()) }),
                (nextMonth, { _ in
                    let last = Day(today.year, today.month + 2, 0).day
                    return setDate(Day(today.year, today.month + 1, min(today.day, last)))
                }),
                (inDays, { m in
                    let n = count(m[1]!), unit = m[2]!
                    if unit.hasPrefix("day") { return setDate(today.adding(n)) }
                    if unit.hasPrefix("week") { return setDate(today.adding(n * 7)) }
                    return setDate(Day(today.year, today.month + n, today.day))
                }),
                (weekdayWord, { m in
                    let weekday = weekdays[String(m[2]!.prefix(3))]!
                    if m[1] == "next" {
                        // "next fri" is the Friday of next week; "fri" is the coming one.
                        let day = upcoming(weekday, includingToday: false)
                        return setDate(day < startOfNextWeek() ? day.adding(7) : day)
                    }
                    weekdayToday = weekday == today.weekday
                    return setDate(upcoming(weekday, includingToday: true))
                }),
                (monthThenDay, { m in setDate(withYear(monthIndex(m[1]!), m.number(2), m.number(3))) }),
                (dayThenMonth, { m in setDate(withYear(monthIndex(m[2]!), m.number(1), m.number(3))) }),
                (isoDate, { m in setDate(validDay(m.number(1), m.number(2) - 1, m.number(3))) }),
                (slashDate, { m in
                    var year = m.number(3)
                    if year != 0 && year < 100 { year += 2000 }
                    return setDate(withYear(m.number(1) - 1, m.number(2), year))
                }),
                (ordinalDay, { m in
                    let day = m.number(1)
                    if let thisMonth = validDay(today.year, today.month, day), thisMonth.text >= today.text { return setDate(thisMonth) }
                    for ahead in 1...3 {
                        if let next = validDay(today.year, today.month + ahead, day) { return setDate(next) }
                    }
                    return false
                }),
            ])
        }

        if time != nil && due == nil { due = today.text }
        // "thu 10am" typed on a Thursday afternoon means next Thursday.
        if weekdayToday, let time, time < nowHM { due = today.adding(7).text }

        var title = replacing(emptyBrackets, in: s, with: " ")
        title = replacing(loosePunctuation, in: title, with: " ")
        title = replacing(spaces, in: title, with: " ")
        title = replacing(ends, in: title, with: "")
        title = replacing(outerSpace, in: title, with: "")
        if title.isEmpty { title = replacing(outerSpace, in: input, with: "") }
        return (title, due, time)
    }

    // tod's patterns, as written in nlp.js (`token` makes its `\s` and `\d` mean here exactly what
    // they do there).
    private static let month = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?"#
    private static let dayName = #"(mon(?:day)?|tue(?:s(?:day)?)?|wed(?:s|nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)"#
    private static let counted = #"(\d{1,3}|an?|one|two|three|four|five|six|seven|eight|nine|ten|twelve)"#
    private static let meridiem = #"(a\.?m\.?|p\.?m\.?)"#
    private static let lead = #"(?:(?:on|by|due|for|until|before|this)\s+)?"#

    private static let hourRange = token(#"(?:(?:at|from)\s+)?(\d{1,2})(?::([0-5]\d))?\s?\#(meridiem)?\s?(?:-|–|to)\s?(\d{1,2})(?::([0-5]\d))?\s?\#(meridiem)"#)
    private static let hourWithMeridiem = token(#"(?:at\s+|@\s?)?(\d{1,2})(?::([0-5]\d))?(?:\s?\#(meridiem)|(a|p))"#)
    private static let clockTime = token(#"(?:at\s+|@\s?)?(\d{1,2}):([0-5]\d)"#)
    private static let noonOrMidnight = token(#"(?:at\s+)?(noon|midday|midnight)"#)
    private static let inHours = token(#"in\s+\#(counted)\s?(hours?|hrs?|h|minutes?|mins?|m)"#)
    private static let atHour = token(#"(?:at|@)\s?(\d{1,2})"#)

    private static let todayWord = token(#"\#(lead)(today|tod|tonight|tonite)"#)
    private static let dayAfterTomorrow = token(#"\#(lead)(?:the\s+)?day\s+after\s+(?:tomorrow|tmrw?)"#)
    private static let tomorrowWord = token(#"\#(lead)(tomorrow|tomorow|tommorow|tommorrow|tmrw|tmr|tmw)"#)
    private static let nextWeekend = token(#"next\s+weekend"#)
    private static let weekend = token(#"\#(lead)weekend"#)
    private static let nextWeek = token(#"next\s+week"#)
    private static let nextMonth = token(#"next\s+month"#)
    private static let inDays = token(#"in\s+\#(counted)\s+(days?|weeks?|months?)"#)
    private static let weekdayWord = token(#"(?:(on|by|due|for|until|before|this|next)\s+)?\#(dayName)"#)
    private static let monthThenDay = token(#"\#(lead)\#(month)\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"#)
    private static let dayThenMonth = token(#"\#(lead)(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?\#(month)(?:,?\s+(\d{4}))?"#)
    private static let isoDate = token(#"(\d{4})-(\d{1,2})-(\d{1,2})"#)
    private static let slashDate = token(#"\#(lead)(\d{1,2})\/(\d{1,2})(?:\/(\d{2}|\d{4}))?"#)
    private static let ordinalDay = token(#"\#(lead)(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)"#)

    /// JavaScript's whitespace (`\s`), which tod squeezes to single spaces before anything else,
    /// so after that its patterns' `\s` only ever meets a plain space.
    private static let jsSpace = #"[\t\n\x{0B}\f\r\x{20}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]"#
    private static let spaceRuns = pattern(jsSpace + "+")
    private static let outerSpace = pattern("^\(jsSpace)+|\(jsSpace)+\\z")    // JavaScript's trim()
    // The title's tidy-up: empty brackets, stray punctuation, doubled spaces, and separators at
    // either end.
    private static let emptyBrackets = pattern(#"\( *\)|\[ *\]"#)
    private static let loosePunctuation = pattern(#"(^| )[.,;:!?]+(?= |\z)"#)
    private static let spaces = pattern(" +")
    private static let ends = pattern(#"^[ ,;:–\-]+|[ ,;:–\-]+\z"#)

    /// One of tod's patterns, which stands on its own: not glued to letters, digits or slashes on
    /// either side.
    private static func token(_ source: String) -> NSRegularExpression {
        let body = source.replacingOccurrences(of: #"\s"#, with: " ").replacingOccurrences(of: #"\d"#, with: "[0-9]")
        return pattern(#"(?<![A-Za-z0-9_/:.])"# + body + #"(?![A-Za-z0-9_/:])"#)
    }

    private static func pattern(_ source: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: source)
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// A–Z lowered and nothing else touched, so the text keeps its length and ICU doesn't match
    /// letters JavaScript wouldn't (like "ſ" for "s").
    private static func asciiLowercased(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { (65...90).contains($0.value) ? Unicode.Scalar($0.value + 32)! : $0 }))
    }

    private static let weekdays = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let numbers = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                  "eight": 8, "nine": 9, "ten": 10, "twelve": 12]

    private static func monthIndex(_ name: String) -> Int { months.firstIndex(of: String(name.prefix(3)))! }
    private static func count(_ word: String) -> Int { numbers[word] ?? Int(word) ?? 0 }
    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    private static func hour12(_ hour: Int, _ meridiem: String) -> Int {
        let pm = meridiem.hasPrefix("p")
        if hour == 12 { return pm ? 12 : 0 }
        return pm ? hour + 12 : hour
    }

    /// "at 5" or "5:30" without am/pm: 1 to 7 are afternoon/evening, 8 to 11 morning.
    private static func guessHour(_ hour: Int) -> Int { (1...7).contains(hour) ? hour + 12 : hour }

    /// The day, if it's a real one (Feb 30 isn't).
    private static func validDay(_ year: Int, _ month: Int, _ day: Int) -> Day? {
        let date = Day(year, month, day)
        return date.month == month && date.day == day ? date : nil
    }

    /// What a pattern caught, lowered.
    private struct Groups {
        let match: NSTextCheckingResult
        let text: NSString

        subscript(_ group: Int) -> String? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }

        /// A group's number, 0 if it caught nothing.
        func number(_ group: Int) -> Int { self[group].flatMap { Int($0) } ?? 0 }
    }

    // MARK: - days

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let weekdayName = formatter("EEE")
    private static let monthDay = formatter("MMMd")
    private static let monthDayYear = formatter("yMMMd")
    private static let hourOnly = formatter("j")
    private static let hourAndMinute: DateFormatter = {
        let made = formatter("jmm")
        // On a 24-hour clock tod writes "0:05", where this template asks for "00:05".
        made.dateFormat = made.dateFormat.replacingOccurrences(of: "HH", with: "H")
        return made
    }()

    /// A calendar day, counted from 1970-01-01, made the way JavaScript's `new Date(year, month,
    /// day)` makes one: month from 0, either rolling over into the next (or last) month or year,
    /// and years 0–99 meaning 1900–1999. tod's rules lean on that.
    private struct Day: Comparable {
        let number: Int

        init(number: Int) {
            self.number = number
        }

        init(_ year: Int, _ month: Int, _ day: Int) {
            let year = (0...99).contains(year) ? 1900 + year : year
            let years = month >= 0 ? month / 12 : (month - 11) / 12    // rounded down
            number = Self.days(year + years, month - years * 12 + 1, 1) + day - 1
        }

        /// The day it is at `date`, here.
        init(_ date: Date) {
            let parts = TodQuick.calendar.dateComponents([.year, .month, .day], from: date)
            self.init(parts.year!, parts.month! - 1, parts.day!)
        }

        var year: Int { Self.civil(number).year }
        var month: Int { Self.civil(number).month - 1 }    // from 0, as in JavaScript
        var day: Int { Self.civil(number).day }
        var weekday: Int { (number % 7 + 11) % 7 }         // 0 is Sunday; 1970-01-01 was a Thursday
        /// "2026-10-30" (the year isn't padded, as tod doesn't pad it).
        var text: String { "\(year)-\(TodQuick.pad(month + 1))-\(TodQuick.pad(day))" }
        /// Midday on it, here, for formatting.
        var noon: Date {
            let (year, month, day) = Self.civil(number)
            return TodQuick.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
        }

        func adding(_ days: Int) -> Day { Day(number: number + days) }

        static func < (a: Day, b: Day) -> Bool { a.number < b.number }

        // Howard Hinnant's day counts for the proleptic Gregorian calendar, as JavaScript uses.
        private static func days(_ year: Int, _ month: Int, _ day: Int) -> Int {
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yearOfEra = y - era * 400
            let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            return era * 146097 + dayOfEra - 719468
        }

        private static func civil(_ number: Int) -> (year: Int, month: Int, day: Int) {
            let z = number + 719468
            let era = (z >= 0 ? z : z - 146096) / 146097
            let dayOfEra = z - era * 146097
            let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365
            let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            let shifted = (5 * dayOfYear + 2) / 153
            let day = dayOfYear - (153 * shifted + 2) / 5 + 1
            let month = shifted < 10 ? shifted + 3 : shifted - 9
            return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
        }
    }
}
