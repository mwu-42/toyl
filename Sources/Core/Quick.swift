import Foundation

/// What a line typed into toyl means. "essay draft fri 5pm #cs ~2h !" is a task called "essay
/// draft", due Friday at 5 PM, in the cs 106b list, taking about two hours, pinned. Piece by
/// piece:
///
/// - `?` first: an idea (into ideas, tod's brain dump), as on Oyl's ideas page.
/// - `#name`: the list whose name it starts (as Oyl's notch reads it: "#cs" is "💻 cs 106b"),
///   or else a tag. `~name` (or `~"two words"`) is always a list, made if there isn't one.
/// - days and times as tod reads them ("fri 5pm", "tomorrow", "in 3 days", "nov 30"): a
///   deadline. Shorthand works too, as in TickTick: `td` today, `tmr` tomorrow, `yd` yesterday,
///   `nw` next week, `nm` next month, `eod`, `eow`, `eom` (end of day, week, month), `wknd`,
///   `nxt fri`, `in 3d` / `2w` / `3mo` (`Shorthand`). Said loosely ("by fri", "next week", "early dec", "in a month or so", "fri-ish"):
///   an aim, a day to have it done by roughly, which can slip (Oyl's distinction). "due" makes
///   anything a deadline.
/// - `every day / weekday / week / other week / month / year`, `every fri`, `every 5th`,
///   `daily`, `weekly`…: it repeats.
/// - `~30m`, `for 2h`, `1h30m`: how long it should take (for timers and the calendar).
/// - `!` or `/pin`: pinned (kept at the top). `/idea` (or `/someday`): put off into ideas.
/// - `/timer`, `/timer 25m`: a timer on it straight away (`/stopwatch` counts up).
/// - ` // ` and anything after it: its notes.
/// - `/list`, `/project`, `/group`, `/filter`, `/event` at the start make that instead (`Command`).
struct Quick: Equatable {
    struct Token: Equatable, Hashable {
        enum Kind: String { case idea, list, newList, tag, due, aim, repeats, duration, pinned, someday, notes, timer }
        let kind: Kind
        let text: String
    }

    var title = ""
    var notes: String?
    var due: String?
    var time: String?
    var target: String?
    var listId: String?
    var newList: String?
    var tags: [String] = []
    var repeats: TodRepeat?
    var duration: Int?
    var pinned = false
    var someday = false
    var idea = false
    /// Nothing was left for a title once everything else was read (it's then the whole line).
    var titleIsEmpty = false
    /// A timer to start on it once it's added.
    var timer: TimerAsk?

    struct TimerAsk: Equatable {
        /// A countdown's length (nil: its own length, else the usual).
        var minutes: Int?
        var stopwatch = false
    }

    static func parse(_ input: String, lists: [ListModel], now: Date = Date(), weekStart: Int = 1) -> Quick {
        var q = Quick()
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Links are set aside first, so nothing in them is read as a list, a tag or a length
        // ("~ouster" in a path, "t=45m" in a query), and they come back whole.
        var links: [String] = []
        text = setAside(links: text, into: &links)
        if text.hasPrefix("?") {
            q.idea = true
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let range = text.range(of: " // ") {
            let notes = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            q.notes = notes.isEmpty ? nil : notes
            text = String(text[..<range.lowerBound])
        }
        if cut(pinPattern, from: &text) { q.pinned = true }
        if cut(somedayPattern, from: &text) { q.someday = true }
        if let match = timerPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let ns = text as NSString
            let stopwatch = ns.substring(with: match.range(at: 1)).lowercased() == "stopwatch"
            var minutes: Int?
            if match.range(at: 2).location != NSNotFound {
                let amount = number(ns.substring(with: match.range(at: 2)))
                let unit = ns.substring(with: match.range(at: 3)).lowercased()
                minutes = max(Self.minutesOf(unit.hasPrefix("h") ? amount * 60 : amount), 1)
            }
            q.timer = TimerAsk(minutes: stopwatch ? nil : minutes, stopwatch: stopwatch)
            text = ns.replacingCharacters(in: match.range, with: " ")
        }
        q.repeats = takeRepeat(&text)
        q.duration = takeDuration(&text)
        takeLists(&text, into: &q, lists: lists)
        // "/nextfri", "/nextweek", "/tmr", "/dec5": a day said as a slash word, in words again.
        text = slashDays(text, now: now, weekStart: weekStart)
        // "td", "tmr", "eow": said in full, for the reading below. Yesterday is toyl's own.
        text = Shorthand.spelledOut(text)
        let saidYesterday = cut(Shorthand.yesterday, from: &text)
        let yesterday = cut(Shorthand.yesterdayShort, from: &text) || saidYesterday

        // Days: a deadline said with "due" first (so "due next week" isn't an aim), else any aim
        // first (so "by fri" isn't a deadline).
        text = text.replacingOccurrences(of: "#", with: hash)
        let today = Day.today(now)
        var read = false
        // Only a time was said (tod makes that today).
        var timeOnly = false
        if matches(dueWord, in: text) {
            // "due" only goes when a day comes with it ("find out when rent is due" keeps it).
            let stripped = replacing(dueWord, in: text, with: " ")
            let hard = TodQuick.read(stripped, now: now, weekStart: weekStart)
            if hard.due != nil || hard.time != nil {
                (q.due, q.time) = (hard.due, hard.time)
                text = consumed(hard, from: stripped) ? "" : hard.title
                q.target = IdeaQuick.takeAim(&text, now: now, weekStart: weekStart)
                timeOnly = hard.time != nil && hard.due == today && !matches(todayWord, in: stripped)
                read = true
            }
        }
        if !read {
            let aim = IdeaQuick.takeAimTimed(&text, now: now, weekStart: weekStart)
            q.target = aim?.day
            let before = text
            let hard = TodQuick.read(text, now: now, weekStart: weekStart)
            (q.due, q.time) = (hard.due, hard.time)
            text = consumed(hard, from: before) ? "" : hard.title
            // A time with no day of its own (tod makes that today).
            let timeAlone = hard.time != nil && hard.due == today && !matches(todayWord, in: before)
            timeOnly = timeAlone && aim == nil
            if let aim {
                if let time = aim.time, q.time == nil {
                    // "by fri 5pm": that day, at that time.
                    q.due = aim.day
                    q.time = time
                } else if timeAlone {
                    // "5pm by fri": the aim's day, at that time.
                    q.due = aim.day
                }
            } else if timeAlone, !yesterday, let time = hard.time, let at = Day.moment(today, time), at < now {
                // "9am" said at 6pm: tomorrow's, not late the moment it's made.
                q.due = Day.adding(1, to: today)
            }
        }
        // "yd", "yesterday 3pm": yesterday (late already: for what's owed).
        if yesterday, q.due == nil || timeOnly { q.due = Day.adding(-1, to: today) }
        // An aim on the same day as the deadline says nothing more.
        if q.target != nil, q.target == q.due { q.target = nil }
        // toyl has no aims any more: "by fri", "next week" are when it's due.
        if let target = q.target {
            if q.due == nil { q.due = target }
            q.target = nil
        }
        // Repeating, with no day said: from today (a weekday one from the next weekday), so it
        // shows in today straight away.
        if let repeats = q.repeats, q.due == nil {
            var first = today
            if repeats == .weekdays, let date = Day.date(today) {
                let weekday = Day.calendar.component(.weekday, from: date)
                first = Day.adding(weekday == 7 ? 2 : weekday == 1 ? 1 : 0, to: today) ?? today
            }
            q.due = first
        }
        q.title = putBack(links: tidy(text).replacingOccurrences(of: hash, with: "#"), links)
        q.notes = q.notes.map { putBack(links: $0, links) }
        q.titleIsEmpty = q.title.isEmpty
        if q.title.isEmpty { q.title = tidy(input.replacingOccurrences(of: "?", with: "", options: .anchored)) }
        return q
    }

    /// Each link replaced by a mark no other reading matches (a private-use character), noted.
    private static func setAside(links text: String, into links: inout [String]) -> String {
        var out = text
        for match in matchesOf(linkPattern, in: text).reversed() {
            let ns = out as NSString
            links.insert(ns.substring(with: match.range), at: 0)
            out = ns.replacingCharacters(in: match.range, with: "\u{E000}")
        }
        return out
    }

    /// The links back where they were.
    private static func putBack(links text: String, _ links: [String]) -> String {
        guard !links.isEmpty else { return text }
        var out = ""
        var next = 0
        for character in text {
            if character == "\u{E000}", next < links.count {
                out += links[next]
                next += 1
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// Whether tod's reading took the whole of `before` (it then hands back all of it as the
    /// title, so a task is never nameless).
    private static func consumed(_ read: (title: String, due: String?, time: String?), from before: String) -> Bool {
        (read.due != nil || read.time != nil) && tidy(read.title) == tidy(before)
    }

    /// As a task to add.
    func draft(source: String? = nil) -> TaskDraft {
        var draft = TaskDraft(title: title)
        draft.notes = notes ?? ""
        draft.due = due
        draft.time = time
        draft.target = target
        draft.listId = idea ? ListModel.dump : listId
        draft.newListName = idea ? nil : newList
        draft.tags = tags
        draft.pinned = pinned
        draft.someday = someday
        draft.repeats = repeats
        draft.duration = duration
        draft.source = source
        return draft
    }

    /// What it was read as, piece by piece, for showing under the field as it's typed.
    func tokens(lists: [ListModel], now: Date = Date()) -> [Token] {
        var out: [Token] = []
        if idea { out.append(Token(kind: .idea, text: "idea")) }
        if let listId, let list = lists.first(where: { $0.id == listId }) { out.append(Token(kind: .list, text: list.displayName)) }
        if let newList { out.append(Token(kind: .newList, text: "new list “\(newList)”")) }
        for tag in tags { out.append(Token(kind: .tag, text: "#" + tag)) }
        if let due {
            out.append(Token(kind: .due, text: "due " + Format.day(due, now: now) + (time.map { " " + Format.time($0) } ?? "")))
        }
        if let target { out.append(Token(kind: .aim, text: Format.aim(target, now: now))) }
        if let repeats { out.append(Token(kind: .repeats, text: repeats.phrase)) }
        if let duration { out.append(Token(kind: .duration, text: "~" + Format.minutes(duration))) }
        if pinned { out.append(Token(kind: .pinned, text: "pinned")) }
        if someday { out.append(Token(kind: .someday, text: "to ideas")) }
        if let timer {
            out.append(Token(kind: .timer, text: timer.stopwatch ? "⏱ stopwatch" : "⏱ " + (timer.minutes.map { Format.minutes($0) + " " } ?? "") + "timer"))
        }
        if notes != nil { out.append(Token(kind: .notes, text: "+ notes")) }
        return out
    }

    // MARK: - lists and tags

    /// `~list` first (always a list), then each `#name`: the first that names a list picks it,
    /// the rest are tags.
    private static func takeLists(_ text: inout String, into q: inout Quick, lists: [ListModel]) {
        let named = lists.filter { !$0.archived }
        for match in matchesOf(explicitList, in: text).reversed() {
            let ns = text as NSString
            let quoted = match.range(at: 1), bare = match.range(at: 2)
            let name = quoted.location != NSNotFound ? ns.substring(with: quoted) : ns.substring(with: bare)
            // "~dec 1" is an aim, and "~30m" a length: not lists.
            if quoted.location == NSNotFound, monthName.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil { continue }
            if q.listId == nil, q.newList == nil {
                // A list it names (its name, or a word of it, or the start of one), else a new
                // one: not any list that happens to contain the letters ("~art" isn't "party").
                if let id = list(for: name, among: named) ?? named.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.id {
                    q.listId = id
                } else {
                    q.newList = name
                }
            }
            text = ns.replacingCharacters(in: match.range, with: " ")
        }
        let ns = text as NSString
        var tags: [String] = []
        var taken: [NSRange] = []
        for match in TodQuick.tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            // "#123" is an issue's number, said as part of the title: not a tag.
            if name.allSatisfy(\.isNumber) { continue }
            taken.append(match.range)
            if q.listId == nil, q.newList == nil, let id = list(for: name, among: named) {
                q.listId = id
            } else if !tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                tags.append(name)
            }
        }
        q.tags = tags
        for range in taken.reversed() { text = (text as NSString).replacingCharacters(in: range, with: " ") }
    }

    /// The list a `#name` means: one whose name (or toyl's name for it: inbox, ideas) is it,
    /// run together, or has a word starting with it ("#cs" → "💻 cs 106b"); nil makes it a tag.
    static func list(for name: String, among lists: [ListModel]) -> String? {
        let key = TodQuick.words(name).joined()
        guard key.count >= 2 else { return nil }
        if let exact = lists.first(where: { $0.handle == key || TodQuick.words($0.displayName).joined() == key }) { return exact.id }
        let named = lists.map { list in (id: list.id, words: TodQuick.words(list.name) + TodQuick.words(list.displayName)) }
        return named.first { $0.words.contains(key) }?.id
            ?? named.first { $0.words.contains { $0.hasPrefix(key) } }?.id
    }

    // MARK: - repeats and lengths

    private static func takeRepeat(_ text: inout String) -> TodRepeat? {
        for (pattern, repeats, template) in repeatRules {
            let whole = NSRange(location: 0, length: (text as NSString).length)
            guard pattern.firstMatch(in: text, range: whole) != nil else { continue }
            text = pattern.stringByReplacingMatches(in: text, range: whole, withTemplate: template)
            return repeats
        }
        return nil
    }

    private static func takeDuration(_ text: inout String) -> Int? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if let match = hoursPattern.firstMatch(in: text, range: whole) {
            let hours = number(ns.substring(with: match.range(at: 1)))
            let minutes = match.range(at: 2).location == NSNotFound ? 0 : number(ns.substring(with: match.range(at: 2)))
            text = ns.replacingCharacters(in: match.range, with: " ")
            let total = Self.minutesOf(hours * 60 + minutes)
            return total > 0 ? min(total, 24 * 60) : nil
        }
        if let match = minutesPattern.firstMatch(in: text, range: whole) {
            let minutes = Self.minutesOf(number(ns.substring(with: match.range(at: 1))))
            text = ns.replacingCharacters(in: match.range, with: " ")
            return minutes > 0 ? min(minutes, 24 * 60) : nil
        }
        return nil
    }

    // MARK: - patterns

    private static let hash = "\u{FF03}"
    private static let linkPattern = pattern(#"(?:https?://|www\.)\S+"#)
    private static let todayWord = pattern(#"\b(?:today|tonight|tod|this\s+(?:morning|afternoon|evening))\b"#)
    private static let pinPattern = pattern(#"(?<!\S)(?:/pin|!{1,3})(?!\S)"#)
    private static let somedayPattern = pattern(#"(?<!\S)/(?:someday|idea|later)(?!\S)"#)
    private static let timerPattern = pattern(#"(?<!\S)/(timer|stopwatch)(?:\s+(\d+(?:[.,]\d+)?)\s?(h|hr|hrs|hours?|m|min|mins|minutes?)\b)?(?!\S)"#)
    private static let dueWord = pattern(#"\bdue(?:\s+(?:by|on|before))?\b"#)
    private static let explicitList = pattern(#"(?<![\p{L}\p{N}_~])~(?:"([^"]+)"|([\p{L}][\p{L}\p{M}\p{N}_\-]*))"#)
    // Only months as they're spelled ("~mar", "~march"): "~marketing" and "~novel" are lists.
    private static let monthName = pattern(#"^(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)$"#)
    private static let weekday = #"(mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)"#
    private static let repeatRules: [(NSRegularExpression, TodRepeat, String)] = [
        (pattern(#"\bevery\s+other\s+week\b|\bbiweekly\b|\bfortnightly\b|\bevery\s+(?:2|two)\s+weeks\b"#), .biweekly, " "),
        (pattern(#"\bevery\s+weekday\b|\bon\s+weekdays\b|\bweekdays\b"#), .weekdays, " "),
        (pattern(#"\bevery\s+"# + weekday + #"\b"#), .weekly, " $1 "),
        (pattern(#"\bevery\s+(?:single\s+)?day\b|\beach\s+day\b|\bdaily\b"#), .daily, " "),
        (pattern(#"\bevery\s+week\b|\beach\s+week\b|\bweekly\b"#), .weekly, " "),
        (pattern(#"\bevery\s+(\d{1,2})(?:st|nd|rd|th)\b"#), .monthly, " the $1th "),
        (pattern(#"\bevery\s+month\b|\beach\s+month\b|\bmonthly\b"#), .monthly, " "),
        (pattern(#"\bevery\s+year\b|\beach\s+year\b|\byearly\b|\bannually\b"#), .yearly, " "),
    ]
    // "for 2h", "~1h30m", "1.5 hours", "45 min" (but "in 2 hours" is a time, for tod's reading).
    private static let hoursPattern = pattern(#"(?<![\p{L}\p{N}/:.])(?<!\bin\s)(?:for\s+(?:about\s+)?|~\s*)?(\d+(?:[.,]\d+)?)\s?(?:h|hr|hrs|hours?)(?:\s?(\d{1,2})\s?(?:m|min|mins|minutes?))?(?![\p{L}\p{N}])"#)
    private static let minutesPattern = pattern(#"(?<![\p{L}\p{N}/:.])(?<!\bin\s)(?:for\s+(?:about\s+)?|~\s*)?(\d{1,3})\s?(?:m|min|mins|minutes?)(?![\p{L}\p{N}])"#)

    private static func pattern(_ source: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    private static func matchesOf(_ pattern: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// Takes every match out; whether there was one.
    private static func cut(_ pattern: NSRegularExpression, from text: inout String) -> Bool {
        guard matches(pattern, in: text) else { return false }
        text = replacing(pattern, in: text, with: " ")
        return true
    }

    private static func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    /// A count of minutes from a number as typed, kept to a week (an enormous one, "200000000000h",
    /// would otherwise not fit in an Int, and stop the program).
    private static func minutesOf(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, 0), 7 * 24 * 60).rounded())
    }

    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—·")))
    }
}

// MARK: - shorthand

/// Days said the quick way, as TickTick takes them: `td`, `tmr`, `yd`, `nw`, `eow`, `in 3d`.
/// Each becomes the words tod's reading knows ("today", "next week", "in 3 days"); yesterday,
/// which tod doesn't know, is toyl's own. The two-letter ones count only in lower case, so "TD
/// Bank" and "NW corner" stay as they are.
enum Shorthand {
    /// A whole word: nothing but a space (or the line's start) before it, no letter after.
    private static func word(_ words: String, caseSensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}#~/@_\x{E000}-])(?:"# + words + #")(?![\p{L}\p{N}_])"#,
                                 options: caseSensitive ? [] : [.caseInsensitive])
    }

    private static let rules: [(NSRegularExpression, String)] = [
        (word("td", caseSensitive: true), "today"),
        (word("tdy|2day|eod"), "today"),
        (word("tmro|tmrow|tmmrw|2moro|2morrow|2mrw"), "tomorrow"),
        (word("nw", caseSensitive: true), "next week"),
        (word("nm", caseSensitive: true), "next month"),
        (word("nxt"), "next"),
        (word("eonw"), "end of next week"),
        (word("eow"), "end of the week"),
        (word("eonm"), "end of next month"),
        (word("eom"), "end of the month"),
        (word("wknd|wkend"), "weekend"),
        (try! NSRegularExpression(pattern: #"\b(next|this)\s+wk\b"#, options: [.caseInsensitive]), "$1 week"),
        (try! NSRegularExpression(pattern: #"\bin\s+(\d{1,3})\s?(?:d|dy|dys)\b"#, options: [.caseInsensitive]), "in $1 days"),
        (try! NSRegularExpression(pattern: #"\bin\s+(\d{1,3})\s?(?:w|wk|wks)\b"#, options: [.caseInsensitive]), "in $1 weeks"),
        (try! NSRegularExpression(pattern: #"\bin\s+(\d{1,3})\s?(?:mo|mos|mth|mths)\b"#, options: [.caseInsensitive]), "in $1 months"),
    ]

    /// Yesterday, said in full or short ("due yesterday", "yday").
    static let yesterday = word(#"(?:(?:due|on|by|for|since)\s+)?(?:yesterday|yday|yest|ystd)"#)
    static let yesterdayShort = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}#~/@_\x{E000}-])(?:(?:[Dd]ue|[Oo]n|[Bb]y|[Ff]or)\s+)?yd(?![\p{L}\p{N}_])"#)

    /// The line with its shorthand said in full.
    static func spelledOut(_ text: String) -> String {
        var out = text
        for (pattern, template) in rules {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: template)
        }
        return out
    }
}

extension Quick {
    /// The words of `input` that were read as something (a day, a list, a tag, a length), to
    /// shade as they're typed: what's left of the line, word for word, is the title, and the rest
    /// was read. Words next to each other are shaded as one. Nothing before a word's been read.
    static func marks(in input: String, read q: Quick) -> [NSRange] {
        let read = q.due != nil || q.time != nil || q.listId != nil || q.newList != nil || !q.tags.isEmpty || q.repeats != nil
            || q.duration != nil || q.pinned || q.someday || q.timer != nil || q.target != nil
        guard read else { return [] }
        let ns = input as NSString
        // Notes aren't read: only what's before " // ".
        let end = ns.range(of: " // ").location == NSNotFound ? ns.length : ns.range(of: " // ").location
        func plain(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "#~")))
        }
        let titleWords = q.titleIsEmpty ? [] : q.title.split(whereSeparator: \.isWhitespace).map { plain(String($0)) }
        var next = 0
        var marks: [NSRange] = []
        let words = (try? NSRegularExpression(pattern: #"\S+"#))?.matches(in: input, range: NSRange(location: 0, length: end)) ?? []
        for match in words {
            let said = ns.substring(with: match.range)
            let word = plain(said)
            // A dash or a comma on its own is neither ("!" is: pinned).
            if word.isEmpty, !said.contains("!") { continue }
            if next < titleWords.count, word == titleWords[next] {
                next += 1
                continue
            }
            if let last = marks.last, ns.substring(with: NSRange(location: NSMaxRange(last), length: match.range.location - NSMaxRange(last)))
                .allSatisfy(\.isWhitespace) {
                marks[marks.count - 1] = NSRange(location: last.location, length: NSMaxRange(match.range) - last.location)
            } else {
                marks.append(match.range)
            }
        }
        return marks
    }
}

// MARK: - making something else

extension Quick {
    /// A line that makes something other than a task: a word after a slash at its start.
    /// - `/list groceries`: a list (`/list` alone: one to name)
    /// - `/project final essay #cs`: a project, in the list named (`#cs`, `~cs`), else the one
    ///   you're in, else the inbox (`/project` alone: one to name)
    /// - `/group school`: a group of lists
    /// - `/filter #cs due:week`: a saved filter (`/filter` alone: the filter field)
    /// - `/event lunch with sam fri noon`: Google Calendar's form, filled in (it asks what's missing)
    /// - `/timer 25m`, `/stopwatch`, with nothing else to name a task: just a timer (with a name,
    ///   "/timer 25m essay" is still a task with a timer on it)
    enum Command: Equatable {
        case list(name: String)
        case project(name: String, listId: String?, newList: String?)
        case group(name: String)
        case filter(query: String)
        case event(title: String, due: String?, time: String?, minutes: Int?)
        case timer(minutes: Int?, stopwatch: Bool)
    }

    /// The words, in the order they're offered while one's being typed, with what each makes.
    static let commands: [(word: String, makes: String)] = [
        ("list", "a list"), ("project", "a project"), ("group", "a group of lists"),
        ("filter", "a saved filter"), ("event", "a calendar event"), ("timer", "a timer"),
    ]
    private static let commandAliases = ["proj": "project", "cal": "event", "calendar": "event"]

    // MARK: days as slash words

    /// Each "/word" that reads as a day, in words: "/nextfri" → "next fri". Others stay as typed.
    private static func slashDays(_ text: String, now: Date, weekStart: Int) -> String {
        var out = text
        for match in matchesOf(slashWord, in: text).reversed() {
            let ns = out as NSString
            guard let phrase = dayPhrase(ns.substring(with: match.range(at: 1)), now: now, weekStart: weekStart) else { continue }
            out = ns.replacingCharacters(in: match.range, with: " " + phrase + " ")
        }
        return out
    }

    private static let slashWord = pattern(#"(?<!\S)/([\p{L}\p{N}]+)(?!\S)"#)
    private static let runTogether: [(NSRegularExpression, String)] = [
        (pattern(#"^endof"#), "end of "),
        (pattern(#"\b(next|this|the)(?=[a-z])"#), "$1 "),
        (pattern(#"^in(?=\d)"#), "in "),
        // "dec5", "fri5pm" → "dec 5", "fri 5pm"; "3days" → "3 days" (but "5pm", "3d" stay whole).
        (pattern(#"(?<=[a-z])(?=\d)|(?<=\d)(?=[a-z]{3,})"#), " "),
    ]

    /// What a slash word means as a day, its words apart again ("nextfri" → "next fri",
    /// "endofmonth" → "end of month", "in3d" → "in 3d"), if it means one; nil if it doesn't.
    static func dayPhrase(_ word: String, now: Date = Date(), weekStart: Int = 1) -> String? {
        var phrase = word.lowercased()
        guard !phrase.contains("/") else { return nil }
        for (pattern, template) in runTogether { phrase = replacing(pattern, in: phrase, with: template) }
        phrase = tidy(phrase)
        let read = parse("x " + phrase, lists: [], now: now, weekStart: weekStart)
        guard read.due != nil, read.title == "x", read.repeats == nil, read.duration == nil, read.tags.isEmpty, read.newList == nil else { return nil }
        return phrase
    }

    /// Days offered in the slash menu, in its order.
    static let dayWords = ["today", "tomorrow", "tonight", "yesterday", "mon", "tue", "wed", "thu", "fri", "sat", "sun",
                           "nextweek", "nextmon", "nexttue", "nextwed", "nextthu", "nextfri", "nextsat", "nextsun",
                           "weekend", "nextweekend", "nextmonth", "endofweek", "endofmonth"]

    /// The days, as slash words, each with the day it is from `now` ("fri dec 4"). Kept for the
    /// day (they're read again for each letter typed after a "/").
    static func daySlashWords(now: Date = Date(), weekStart: Int = 1) -> [SlashWord] {
        let key = Day.today(now) + "|\(weekStart)"
        return DayWordsKept.shared.words(for: key) { readDayWords(now: now, weekStart: weekStart) }
    }

    private static func readDayWords(now: Date, weekStart: Int) -> [SlashWord] {
        dayWords.compactMap { word in
            guard let phrase = dayPhrase(word, now: now, weekStart: weekStart),
                  let due = parse("x " + phrase, lists: [], now: now, weekStart: weekStart).due, let date = Day.date(due) else { return nil }
            return SlashWord(word: word, says: "due " + dayName.string(from: date).lowercased())
        }
    }

    /// The slash menu's days, read once a day.
    private final class DayWordsKept: @unchecked Sendable {
        static let shared = DayWordsKept()
        private let lock = NSLock()
        private var key = ""
        private var kept: [SlashWord] = []

        func words(for key: String, _ read: () -> [SlashWord]) -> [SlashWord] {
            lock.lock()
            defer { lock.unlock() }
            if key != self.key {
                kept = read()
                self.key = key
            }
            return kept
        }
    }

    private static let dayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d"
        return formatter
    }()

    /// A slash word for the menu under the field: the word, and what it does.
    struct SlashWord: Equatable, Hashable {
        let word: String
        let says: String
    }

    /// At the start of a line: what the line can make, then what can go on a task.
    static let lineWords: [SlashWord] = commands.filter { $0.word != "timer" }.map { SlashWord(word: $0.word, says: $0.makes) } + [
        SlashWord(word: "timer", says: "a timer (on the task, if one's named)"),
        SlashWord(word: "stopwatch", says: "a stopwatch (likewise)"),
        SlashWord(word: "pin", says: "a task kept at the top"),
        SlashWord(word: "idea", says: "a task put off into ideas"),
    ]
    /// After a task's words: what can go on it.
    static let taskWords: [SlashWord] = [
        SlashWord(word: "timer", says: "a timer on it (/timer 25m)"),
        SlashWord(word: "stopwatch", says: "a stopwatch on it"),
        SlashWord(word: "pin", says: "kept at the top"),
        SlashWord(word: "idea", says: "put off into ideas"),
    ]

    /// The slash word being typed at the end ("/", "/pro", "essay /ti"): where it is, and the
    /// words it could be, for the menu under the field. Nil once it's a whole word, or for a slash
    /// inside a word ("a/b", a link).
    static func slashMenu(_ input: String, now: Date = Date(), weekStart: Int = 1) -> (range: Range<String.Index>, words: [SlashWord])? {
        guard let slash = input.lastIndex(of: "/") else { return nil }
        let typed = input[input.index(after: slash)...]
        guard typed.allSatisfy(\.isLetter) else { return nil }
        let before = input[..<slash]
        if let last = before.last, !last.isWhitespace { return nil }
        let key = typed.lowercased()
        // At the start, what a line makes, then days; after words, days first ("essay /nextfri").
        let days = daySlashWords(now: now, weekStart: weekStart)
        let offered = before.allSatisfy(\.isWhitespace) ? lineWords + days : days + taskWords
        let words = offered.filter { $0.word.hasPrefix(key) && $0.word != key }
        return words.isEmpty ? nil : (slash..<input.endIndex, words)
    }

    /// A command word being typed at the start, nothing after it yet ("/pro"): the words it could
    /// finish as.
    static func commandsStarting(_ input: String) -> [(word: String, makes: String)] {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let typed = text.dropFirst().lowercased()
        return commands.filter { $0.word.hasPrefix(typed) && $0.word != typed }
    }

    static func command(_ input: String, lists: [ListModel], now: Date = Date(), weekStart: Int = 1) -> Command? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let word = String(text.dropFirst().prefix { !$0.isWhitespace })
        let rest = String(text.dropFirst(1 + word.count)).trimmingCharacters(in: .whitespaces)
        switch commandAliases[word.lowercased()] ?? word.lowercased() {
        case "list":
            return .list(name: tidy(rest))
        case "group":
            return .group(name: tidy(rest))
        case "filter":
            return .filter(query: rest)
        case "project":
            var name = rest
            var q = Quick()
            takeLists(&name, into: &q, lists: lists)
            // A #word that isn't a list was part of the name.
            return .project(name: tidy(([name] + q.tags.map { "#" + $0 }).joined(separator: " ")), listId: q.listId, newList: q.newList)
        case "event":
            guard !rest.isEmpty else { return .event(title: "", due: nil, time: nil, minutes: nil) }
            let q = parse(rest, lists: lists, now: now, weekStart: weekStart)
            return .event(title: q.titleIsEmpty ? "" : q.title, due: q.due, time: q.time, minutes: q.duration)
        case "timer", "stopwatch":
            let q = parse(text, lists: lists, now: now, weekStart: weekStart)
            guard q.titleIsEmpty, let timer = q.timer else { return nil }
            return .timer(minutes: timer.minutes, stopwatch: timer.stopwatch)
        default:
            return nil
        }
    }
}
