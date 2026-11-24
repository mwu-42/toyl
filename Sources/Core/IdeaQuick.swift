// Copied from Oyl (Sources/Ideas.swift, its IdeaQuick) so an aim ("by fri", "early dec", "in a
// month or so") reads in toyl just as it does on Oyl's ideas page. `takeAim` is opened up for
// toyl's quick add; otherwise unchanged. Keep the two in step.

import Foundation

/// What a line typed into the ideas field means: "essay due fri" is due Friday; "learn to make
/// pasta in a month or so" is aimed at a month from now; "sauna" is for someday. Deadlines are
/// read as tod reads them ("due", or a day on its own: "fri 5pm", "dec 5", "tomorrow"); aims are
/// a while off ("in 3 weeks", "next month", "early dec"), or any day said loosely ("by fri",
/// "around the 5th", "next week-ish", "~dec 1").
struct IdeaQuick: Equatable {
    let title: String
    let due: String?      // "YYYY-MM-DD", a deadline
    let time: String?     // "HH:MM"
    let target: String?   // "YYYY-MM-DD", an aim

    static func parse(_ input: String, now: Date = Date(), weekStart: Int = 1) -> IdeaQuick {
        // "#" is only ever text here: tod's quick add would take it for a list.
        var text = replacing(spaces, in: input.replacingOccurrences(of: "#", with: Self.hash), with: " ")
        var due: String?, time: String?, target: String?
        let hasDue = matches(dueWord, in: text)
        if hasDue {
            // The deadline first, so "due next week" isn't taken for an aim.
            text = replacing(dueWord, in: text, with: " ")
            let hard = TodQuick.parse(text, now: now, weekStart: weekStart)
            due = hard.due
            time = hard.time
            text = hard.title
            target = takeAim(&text, now: now, weekStart: weekStart)
        } else {
            target = takeAim(&text, now: now, weekStart: weekStart)
            let hard = TodQuick.parse(text, now: now, weekStart: weekStart)
            due = hard.due
            time = hard.time
            text = hard.title
        }
        let title = replacing(spaces, in: text, with: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—")))
            .replacingOccurrences(of: Self.hash, with: "#")
        return IdeaQuick(title: title, due: due, time: time, target: target)
    }

    /// "Today" … "Fri" … "Dec 5", as tod says a day, for a deadline; and its time, if it has one.
    static func describe(due: String, time: String?, now: Date = Date()) -> String {
        let day = TodQuick.describe(due: due, now: now)
        return time.map { day + " " + TodQuick.describe(time: $0) } ?? day
    }

    /// An aim, said as loosely as it was meant: "by Fri" within the week, else "early Dec",
    /// "mid Dec", "late Dec" ("late Dec 2027" in another year).
    static func describe(target: String, now: Date = Date()) -> String {
        guard let day = date(target) else { return target }
        let today = calendar.startOfDay(for: now)
        let ahead = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        if (0...6).contains(ahead) {
            switch ahead {
            case 0: return "by today"
            case 1: return "by tomorrow"
            default: return "by " + weekdayName.string(from: day)
            }
        }
        let parts = calendar.dateComponents([.year, .day], from: day)
        let part = parts.day! <= 10 ? "early" : parts.day! <= 20 ? "mid" : "late"
        let month = monthName.string(from: day)
        let year = parts.year == calendar.component(.year, from: now) ? "" : " \(parts.year!)"
        return "\(part) \(month)\(year)"
    }

    // MARK: - aims

    /// Takes the first aim out of `text`, if there's one: its day.
    static func takeAim(_ text: inout String, now: Date, weekStart: Int) -> String? {
        takeAimTimed(&text, now: now, weekStart: weekStart)?.day
    }

    /// The first aim, with the time said with it ("by fri 5pm"), if one was.
    static func takeAimTimed(_ text: inout String, now: Date, weekStart: Int) -> (day: String, time: String?)? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        // A while off ("in a month or so", "next week", "early dec"): an aim, said loosely or not.
        for match in horizon.matches(in: text, range: whole) {
            guard let day = resolve(match, in: ns, now: now, weekStart: weekStart) else { continue }
            text = ns.replacingCharacters(in: match.range, with: " ")
            return (day, nil)
        }
        // A day said loosely: "by fri", "around the 5th", "~dec 1", "tomorrow-ish".
        for match in loose.matches(in: text, range: whole) {
            let after = ns.substring(from: match.range.location + match.range.length)
            let words = after.split(separator: " ", omittingEmptySubsequences: true).prefix(3).map(String.init)
            for count in stride(from: words.count, through: 1, by: -1) {
                let phrase = words.prefix(count).joined(separator: " ")
                let read = TodQuick.parse(phrase.replacingOccurrences(of: Self.hash, with: ""), now: now, weekStart: weekStart)
                guard let due = read.due, Self.isOnlyADay(read.title, phrase) else { continue }
                let span = (after as NSString).range(of: phrase)
                guard span.location != NSNotFound else { continue }
                var end = match.range.location + match.range.length + span.location + span.length
                if let tail = trailingSoft.firstMatch(in: text, range: NSRange(location: end, length: whole.length - end)),
                   tail.range.location == end {
                    end += tail.range.length
                }
                text = ns.replacingCharacters(in: NSRange(location: match.range.location, length: end - match.range.location), with: " ")
                return (due, read.time)
            }
        }
        // A day with a loose ending: "fri-ish", "dec 5 or so".
        if let tail = trailingSoft.firstMatch(in: text, range: whole) {
            let before = ns.substring(to: tail.range.location)
            let words = before.split(separator: " ", omittingEmptySubsequences: true).suffix(3).map(String.init)
            for count in stride(from: words.count, through: 1, by: -1) {
                let phrase = words.suffix(count).joined(separator: " ")
                let read = TodQuick.parse(phrase.replacingOccurrences(of: Self.hash, with: ""), now: now, weekStart: weekStart)
                guard let due = read.due, Self.isOnlyADay(read.title, phrase), before.hasSuffix(phrase) || before.hasSuffix(phrase + " ") else { continue }
                let start = (before as NSString).range(of: phrase, options: .backwards).location
                guard start != NSNotFound else { continue }
                text = ns.replacingCharacters(in: NSRange(location: start, length: tail.range.location + tail.range.length - start), with: " ")
                return (due, read.time)
            }
        }
        return nil
    }

    /// What's left of `phrase` once tod's read its day (`title`) is nothing: tod keeps the whole
    /// line as the title when there'd be none.
    private static func isOnlyADay(_ title: String, _ phrase: String) -> Bool {
        let left = title.trimmingCharacters(in: .whitespaces)
        return left.isEmpty || left.caseInsensitiveCompare(phrase.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// The day a horizon means: a span from today ("in 3 weeks"), the end of this or next week
    /// or month, or a part of a month ("early dec" the 7th, "mid" the 15th, "late" its last day;
    /// "by dec" its 1st, "dec" its 15th).
    private static func resolve(_ match: NSTextCheckingResult, in text: NSString, now: Date, weekStart: Int) -> String? {
        func group(_ name: String) -> String? {
            let range = match.range(withName: name)
            return range.location == NSNotFound ? nil : text.substring(with: range).lowercased()
        }
        let today = calendar.startOfDay(for: now)
        if let unit = group("unit"), let amount = group("amount").map(Self.amount) {
            // A span only with a word to say it's one ("in 3 weeks", "2 weeks or so"): "review 3
            // months of statements" and "plan 2 weeks of meals" are counts, not days.
            let said = text.substring(with: match.range).lowercased()
            guard said.range(of: #"^(?:by|in|within|around|about|roughly|sometime|aim(?:ing)?\s+for|~)\b|^~|(?:or\s+so|ish)$"#,
                             options: .regularExpression) != nil else { return nil }
            let component: Calendar.Component = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear : .month
            return calendar.date(byAdding: component, value: amount, to: today).map(day)
        }
        if let which = group("which"), let span = group("span") {
            let next = which.contains("next")
            if span.hasPrefix("weekend") {
                let sunday = (1 - calendar.component(.weekday, from: today) + 7) % 7
                return calendar.date(byAdding: .day, value: sunday + (next ? 7 : 0), to: today).map(day)
            }
            if span.hasPrefix("week") {
                // The last day of this week (or next), as tod's weeks start.
                let weekday = calendar.component(.weekday, from: today) - 1
                let toStart = (weekStart - weekday + 7) % 7
                return calendar.date(byAdding: .day, value: (toStart == 0 ? 7 : toStart) - 1 + (next ? 7 : 0), to: today).map(day)
            }
            guard let month = calendar.date(byAdding: .month, value: next ? 1 : 0, to: today),
                  let last = calendar.range(of: .day, in: .month, for: month)?.count else { return nil }
            var parts = calendar.dateComponents([.year, .month], from: month)
            parts.day = last
            return calendar.date(from: parts).map(day)
        }
        if let name = group("month"), let number = months.firstIndex(where: { name.hasPrefix($0) }) {
            let part = group("part")
            let by = group("by") != nil
            // A month on its own only with a word to say it's one ("by may", "in march", "early
            // june"): "may" and "march" are words too.
            let said = text.substring(with: match.range).lowercased()
            guard part != nil || said.range(of: #"^(?:by|in|around|about|roughly|sometime|aim(?:ing)?\s+for|~)"#, options: .regularExpression) != nil
            else { return nil }
            var parts = DateComponents(year: calendar.component(.year, from: today), month: number + 1, day: 1)
            guard let first = calendar.date(from: parts), let length = calendar.range(of: .day, in: .month, for: first)?.count else { return nil }
            switch part {
            case let part? where part.hasPrefix("early"): parts.day = 7
            case let part? where part.hasPrefix("mid"): parts.day = 15
            case .some: parts.day = length
            case nil: parts.day = by ? 1 : 15
            }
            guard var date = calendar.date(from: parts) else { return nil }
            // A month that's over: next year's. This month: this one (not before today).
            let monthEnd = calendar.date(from: DateComponents(year: parts.year, month: number + 1, day: length)) ?? date
            if monthEnd < today, let later = calendar.date(byAdding: .year, value: 1, to: date) {
                date = later
            } else if date < today {
                date = today
            }
            return day(date)
        }
        return nil
    }

    private static func amount(_ word: String) -> Int {
        let word = word.trimmingCharacters(in: .whitespaces)
        if let number = Int(word) { return number }
        if word.contains("couple") { return 2 }
        if word.contains("few") { return 3 }
        if word.contains("several") { return 4 }
        return ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                "ten": 10][word] ?? 1
    }

    // MARK: - patterns

    private static let hash = "\u{FF03}"
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let softBefore = #"(?:by|around|about|roughly|sometime|within|aim(?:ing)?\s+for|~)"#
    private static let softAfter = #"(?:\s+or\s+so|(?:\s+|-)ish)"#

    /// A horizon, a while off, with whatever loose words go with it.
    private static let horizon = pattern(
        #"(?:(?<by>\bby)\s+|\b(?:around|about|roughly|sometime|aim(?:ing)?\s+for|in)\s+|~\s*)*"#
        + #"(?:"#
        + #"(?:\b(?:in|within)\s+)?(?:about\s+|roughly\s+)?(?<amount>\b(?:\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|(?:a\s+)?couple(?:\s+of)?|(?:a\s+)?few|several))\s+(?<unit>(?:week|month)s?|days?(?=\s+or\s+so|(?:\s+|-)ish))\b"#
        + #"|\b(?:the\s+)?(?:end\s+of\s+)?(?:the\s+)?(?<which>this|next|end\s+of\s+(?:the|this)?|end\s+of\s+next)\s*(?<span>weekend|week|month)\b"#
        + #"|\b(?<part>early|mid|late|end\s+of)?\s*-?\s*(?<month>jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b(?!\s*\d)"#
        + #")"# + softAfter + "?")

    /// A loose word before a day: "by", "around", "~"…
    private static let loose = pattern(#"(?:\b(?:by|around|about|roughly|sometime|aim(?:ing)?\s+for)\b|~)\s*"#)
    /// A loose ending after one: "or so", "-ish".
    private static let trailingSoft = pattern(softAfter + #"\b"#)
    private static let dueWord = pattern(#"\bdue(?:\s+(?:by|on|before))?\b"#)
    private static let spaces = pattern(#"\s+"#)

    private static func pattern(_ source: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    // MARK: - days

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year!)-" + String(format: "%02d-%02d", parts.month!, parts.day!)
    }

    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static let weekdayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private static let monthName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()
}
