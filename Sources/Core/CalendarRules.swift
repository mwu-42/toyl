import Foundation

/// The owner's rules for their Google calendar (CALENDAR.md has them in words): how every event
/// is written, which sub-calendar and label it goes on, and what's asked rather than guessed.
/// Kept in calendar-rules.json in toyl's folder, so they can be changed without a new toyl.
struct CalendarRules: Codable, Equatable {
    /// One of the sub-calendars: its key ("a"), its name in Google ("✩ a"), what it's for, its
    /// labels, and what no label means.
    struct Sub: Codable, Equatable, Identifiable {
        var key: String
        var name: String
        var about: String
        var labels: [String]
        var none: String?
        /// m: descriptions can say more there.
        var descriptive = false
        /// m: nothing sits on it that's also on another calendar.
        var dedupe = false

        var id: String { key }
    }

    /// Words that settle where something goes ("album" → r, music).
    struct Place: Codable, Equatable {
        var words: [String]
        var calendar: String
        var label: String?
    }

    var calendars: [Sub]
    var places: [Place]
    /// What a label's for, by "calendar/label" ("g/food": "meals out").
    var notes: [String: String]
    /// Kept out of rundowns (today, the agenda), and never reminded of.
    var skip: [String]
    /// Standing events that are there already, not to be added again.
    var standing: [String]
    /// A label's id in Google, by "calendar/label", where its name there doesn't say it.
    var labelIds: [String: String] = [:]

    static let standard = CalendarRules(
        calendars: [
            Sub(key: "♡", name: "♡", about: "primary, the main calendar", labels: []),
            Sub(key: "a", name: "✩ a", about: "academic", labels: ["cs 106b", "college 101", "pwr 1ju", "math 61cm"], none: "general school"),
            Sub(key: "c", name: "✩ c", about: "celebrations", labels: ["holiday"], none: "birthday"),
            Sub(key: "e", name: "✩ e", about: "events", labels: ["music"], none: "everything else"),
            Sub(key: "g", name: "✩ g", about: "fun", labels: ["culture", "food"], none: "other fun, grocery runs"),
            Sub(key: "r", name: "✩ r", about: "reminders", labels: ["flight", "music"], none: "random reminders, chores"),
            Sub(key: "v", name: "✩ v", about: "vacations", labels: []),
            Sub(key: "x", name: "✩ x", about: "extracurriculars", labels: ["aasa", "treehacks", "mint", "ssi", "smun"], none: "other club"),
            Sub(key: "m", name: "✶ m", about: "misc, usually hidden", labels: [], descriptive: true, dedupe: true),
        ],
        places: [
            Place(words: ["all hands", "all-hands", "margs"], calendar: "x", label: "mint"),
            Place(words: ["album", "album drop", "release", "drops", "new single", "new music"], calendar: "r", label: "music"),
            Place(words: ["flight", "fly to", "flying to", "flight to"], calendar: "r", label: "flight"),
            Place(words: ["change sheets", "vacuum", "laundry", "chores", "clean my room", "take out the trash", "dishes"], calendar: "r"),
            Place(words: ["trader joe", "trader joes", "trader joe's", "groceries", "grocery run", "grocery"], calendar: "g"),
            Place(words: ["lunch with", "dinner with", "brunch", "breakfast with", "coffee with", "boba with", "lunch at", "dinner at"], calendar: "g", label: "food"),
            Place(words: ["movie", "film", "musical", "broadway", "screening", "watch party"], calendar: "g", label: "culture"),
            Place(words: ["concert", "gig", "festival"], calendar: "e", label: "music"),
            Place(words: ["birthday", "bday"], calendar: "c"),
            Place(words: ["holiday", "thanksgiving", "christmas", "new year's", "lunar new year"], calendar: "c", label: "holiday"),
            Place(words: ["vacation"], calendar: "v"),
        ],
        notes: ["g/culture": "movies and shows", "g/food": "meals out", "r/music": "releases and album drops", "e/music": "shows and concerts",
                "c/holiday": "holidays", "r/flight": "flights"],
        skip: ["floor meeting"],
        standing: ["buy things thursday"]
    )

    static var file: URL { Paths.home.appendingPathComponent("calendar-rules.json") }

    /// The rules as kept (written the first time from the standard ones).
    static func load() -> CalendarRules {
        if let data = try? Data(contentsOf: file), let rules = try? JSONDecoder().decode(CalendarRules.self, from: data) { return rules }
        standard.save()
        return standard
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    // MARK: - finding calendars

    /// A sub-calendar, from its key ("a"), its name ("✩ a") or what it's for ("academic").
    func sub(_ ref: String) -> Sub? {
        let ref = ref.trimmingCharacters(in: .whitespaces).lowercased()
        guard !ref.isEmpty else { return nil }
        if ["primary", "main", "♡ primary"].contains(ref) { return calendars.first { $0.key == "♡" } }
        return calendars.first { $0.key.lowercased() == ref || $0.name.lowercased() == ref }
            ?? calendars.first { $0.about.lowercased() == ref || $0.about.lowercased().hasPrefix(ref + ",") || ($0.name + " " + $0.about).lowercased() == ref }
    }

    /// The Google calendar a sub-calendar is.
    func calendar(for sub: Sub, in calendars: [GCalendar]) -> GCalendar? {
        if sub.key == "♡", let primary = calendars.first(where: \.primary) { return primary }
        return calendars.first { $0.name.trimmingCharacters(in: .whitespaces) == sub.name }
    }

    /// The sub-calendar a Google calendar is, if it's one of them.
    func sub(for calendar: GCalendar) -> Sub? {
        if calendar.primary, let main = calendars.first(where: { $0.key == "♡" }) { return main }
        return calendars.first { $0.name == calendar.name.trimmingCharacters(in: .whitespaces) }
    }

    /// A calendar from what someone called it: its id, key, name, or what it's for.
    func resolve(_ ref: String, in calendars: [GCalendar]) -> GCalendar? {
        if let exact = calendars.first(where: { $0.id == ref }) { return exact }
        if let sub = sub(ref) { return calendar(for: sub, in: calendars) }
        return calendars.first { $0.name.caseInsensitiveCompare(ref.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    /// A label on a calendar, by name (or the id it was matched to when its name didn't say).
    func label(_ name: String, on calendar: GCalendar) -> GLabel? {
        let key = (sub(for: calendar)?.key ?? calendar.id) + "/" + name.lowercased()
        if let id = labelIds[key], let mapped = calendar.labels.first(where: { $0.id == id }) { return mapped }
        return calendar.label(named: name)
    }

    /// Whether an event's kept out of rundowns (a floor meeting).
    func skips(_ title: String) -> Bool {
        let text = Query.fold(title)
        return skip.contains { text.contains(Query.fold($0)) }
    }

    // MARK: - where it goes

    struct Placement: Equatable {
        var key: String?
        var label: String?
        var reason: String
        /// Settled by a rule; otherwise only a guess, to be asked about.
        var sure: Bool
    }

    /// Where an event belongs: by what its words say ("lunch with" → g, food), else by its
    /// task's list or tags matching a label ("💻 cs 106b" → a, cs 106b); else nowhere yet (ask).
    func place(_ title: String, list: ListModel? = nil, tags: [String] = []) -> Placement {
        let text = " " + Self.plain(title) + " "
        for place in places {
            if let hit = place.words.first(where: { text.contains(" " + Self.plain($0) + " ") }) {
                return Placement(key: place.calendar, label: place.label, reason: "“\(hit)”", sure: true)
            }
        }
        if let list, !list.isSpecial {
            let handle = TodQuick.words(list.bareName).joined()
            let hits = calendars.flatMap { sub in sub.labels.filter { TodQuick.words($0).joined() == handle }.map { (sub, $0) } }
            if hits.count == 1 { return Placement(key: hits[0].0.key, label: hits[0].1, reason: "its list, \(list.bareName)", sure: true) }
        }
        for tag in tags {
            let handle = TodQuick.words(tag).joined()
            let hits = calendars.flatMap { sub in sub.labels.filter { TodQuick.words($0).joined() == handle }.map { (sub, $0) } }
            if hits.count == 1 { return Placement(key: hits[0].0.key, label: hits[0].1, reason: "its tag, #\(tag)", sure: true) }
            if hits.count > 1 {
                return Placement(key: nil, label: hits[0].1, reason: "#\(tag) could go on " + hits.map(\.0.name).joined(separator: " or "), sure: false)
            }
        }
        return Placement(key: nil, label: nil, reason: "nothing says where it goes", sure: false)
    }

    private static func plain(_ text: String) -> String {
        let kept = String(Query.fold(text).map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " })
        return kept.split(separator: " ").joined(separator: " ")
    }
}

/// How every event is written: lower case through and through (titles, descriptions,
/// locations), no em dashes anywhere, no "#" in titles ("tic letter 2 due", not "#2").
enum CalendarStyle {
    static func title(_ text: String) -> String {
        var title = text.lowercased()
        title = title.replacingOccurrences(of: "—", with: " ").replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "#", with: "")
        return title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A description or location: lower case, no em dashes, its lines kept (a giveaway's
    /// free stuff goes one to a line).
    static func text(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: "—", with: ", ").replacingOccurrences(of: "–", with: "-")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What someone asked to put on the calendar.
struct EventRequest {
    var title = ""
    var calendar: String?
    /// A label's name, or "none".
    var label: String?
    var day: String?
    var start: String?
    var end: String?
    var minutes: Int?
    var allDay = false
    var location = ""
    var description = ""
    var taskId: String?
    var tentative = false
    /// For a mint all hands: margs after it.
    var margs = true
}

/// What toyl would add, or what it needs to know first.
struct EventOutcome {
    var plans: [EventPlan] = []
    var questions: [String] = []
    var notes: [String] = []
    /// Copies on m that go once this is added elsewhere.
    var offM: [GEvent] = []
    var placement: CalendarRules.Placement?
    var calendar: GCalendar?
    var labelName: String?
}

/// Turns a request into events, the owner's way: only what's been given (a missing day, time or
/// place is asked about, and a start with no end asks how long), written their way, on the
/// sub-calendar and label the rules say, never on a calendar or label that isn't there already.
enum CalendarPlanner {
    static let allHands = try! NSRegularExpression(pattern: #"^\s*(?:mint\s+)?all[\s-]?hands\b\s*(?:#?\s*(\d+))?\s*[:,\-–—]?\s*(.*)$"#, options: [.caseInsensitive])

    static func plan(_ request: EventRequest, rules: CalendarRules, calendars: [GCalendar], existing: [GEvent],
                     snap: Snapshot? = nil, now: Date = Date()) -> EventOutcome {
        var outcome = EventOutcome()
        var r = request
        let weekStart = snap?.weekStart ?? 1

        // mint all hands: "all hands" and its number, the topic below, thursday 7:30-8:30pm at
        // pigott hall 260-113; margs after, 8:30-9pm at treehouse; both x, mint.
        var isAllHands = false
        let whole = NSRange(location: 0, length: (r.title as NSString).length)
        if let match = allHands.firstMatch(in: r.title, range: whole) {
            isAllHands = true
            let ns = r.title as NSString
            let number = match.range(at: 1).location == NSNotFound ? nil : ns.substring(with: match.range(at: 1))
            let topic = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            if let number { r.title = "all hands \(number)" } else { outcome.questions.append("which all hands is it? (its number)") }
            if r.description.isEmpty { r.description = topic }
            r.calendar = r.calendar ?? "x"
            r.label = r.label ?? "mint"
            r.start = r.start ?? "19:30"
            r.end = r.end ?? "20:30"
            if r.location.isEmpty { r.location = "pigott hall 260-113" }
        }

        // The title, their way.
        var title = CalendarStyle.title(r.title)
        if r.tentative, !title.hasSuffix("?") { title += "?" }
        if title.isEmpty { outcome.questions.append("what should it be called?") }
        if rules.standing.contains(where: { CalendarStyle.title($0) == title.trimmingCharacters(in: CharacterSet(charactersIn: "?")) }) {
            outcome.questions.append("“\(title)” is a standing event on r already")
        }

        // Where: what was said, else what the rules say.
        let task = r.taskId.flatMap { snap?.task($0) }
        let placement = rules.place(r.title, list: task.flatMap { snap?.list($0.listId) }, tags: task?.tags ?? [])
        outcome.placement = placement
        var calendar: GCalendar?
        if let ref = r.calendar, !ref.isEmpty {
            calendar = rules.resolve(ref, in: calendars)
            if calendar == nil { outcome.questions.append("there's no calendar “\(ref)” in your google calendar (toyl doesn't make new ones without asking)") }
        } else if placement.sure, let key = placement.key, let sub = rules.sub(key) {
            calendar = rules.calendar(for: sub, in: calendars)
            if calendar == nil { outcome.questions.append("\(sub.name) isn't among your google calendars") }
        } else {
            let hint = placement.reason.isEmpty || placement.reason == "nothing says where it goes" ? "" : " (" + placement.reason + ")"
            outcome.questions.append("which calendar should it go on? " + rules.calendars.map(\.key).joined(separator: ", ") + hint)
        }
        if let calendar, !calendar.writable { outcome.questions.append("\(calendar.name) can only be read, not added to") }
        outcome.calendar = calendar
        let sub = calendar.flatMap { rules.sub(for: $0) }

        // Which label: what was said, else the rules' (if it's this calendar's).
        var label: GLabel?
        let wanted = r.label ?? (placement.sure && placement.key == sub?.key ? placement.label : nil)
        if let calendar, let wanted, wanted.lowercased() != "none", !wanted.isEmpty {
            if let found = rules.label(wanted, on: calendar) {
                label = found
                outcome.labelName = found.name.isEmpty ? wanted : found.name
            } else {
                outcome.questions.append("“\(wanted)” isn't a label on \(calendar.name) in google yet. pick one of its labels, or say no label (toyl doesn't make labels without asking)")
            }
        }

        // When: a day, and a start and an end (or all day). Nothing's assumed.
        let day = r.day.flatMap { Ops.day($0, weekStart: weekStart, now: now) }.flatMap { $0 }
        if day == nil { outcome.questions.append(isAllHands ? "which thursday?" : "what day is it?") }
        var start: String?, end: String?
        if !r.allDay {
            start = r.start.flatMap { Ops.time($0, now: now) }.flatMap { $0 }
            if start == nil { outcome.questions.append("what time does it start, or is it all day?") }
            if let text = r.end { end = Ops.time(text, now: now).flatMap { $0 } }
            if end == nil, let minutes = r.minutes, minutes > 0, let start, let from = Day.moment(day ?? Day.today(now), start) {
                end = Day.clock(from.addingTimeInterval(Double(minutes) * 60))
            }
            if start != nil, end == nil { outcome.questions.append("how long should it run? (there's no standing length)") }
        }
        if isAllHands, let day, let date = Day.date(day), Day.calendar.component(.weekday, from: date) != 5 {
            outcome.notes.append("all hands are usually thursdays")
        }

        // m: nothing there that's on another calendar too.
        if let calendar, let day, !title.isEmpty {
            let mine = existing.filter { $0.day == day && CalendarStyle.title($0.title) == title && $0.status != "cancelled" }
            if sub?.dedupe == true {
                if let elsewhere = mine.first(where: { $0.calendarId != calendar.id }) {
                    let name = calendars.first { $0.id == elsewhere.calendarId }?.name ?? "another calendar"
                    outcome.questions.append("that's already on \(name), and nothing on m is on another calendar too")
                }
            } else if let m = rules.calendars.first(where: \.dedupe).flatMap({ rules.calendar(for: $0, in: calendars) }) {
                outcome.offM = mine.filter { $0.calendarId == m.id }
                if !outcome.offM.isEmpty { outcome.notes.append("takes the copy off \(m.name)") }
            }
        }

        // Descriptions stay minimal (blank unless something's given); m's can say more.
        let description = CalendarStyle.text(r.description)
        if sub?.descriptive != true, description.count > 140 { outcome.notes.append("that's a long description for anywhere but m") }

        guard outcome.questions.isEmpty, let calendar, let day else { return outcome }
        outcome.plans.append(EventPlan(title: title, calendarId: calendar.id, labelId: label?.id, day: day, start: r.allDay ? nil : start,
                                       end: r.allDay ? nil : end, allDay: r.allDay, location: CalendarStyle.text(r.location),
                                       description: description, taskId: r.taskId))
        if isAllHands, r.margs {
            outcome.plans.append(EventPlan(title: "margs", calendarId: calendar.id, labelId: label?.id, day: day, start: "20:30", end: "21:00",
                                           allDay: false, location: "treehouse", description: "", taskId: nil))
            outcome.notes.append("margs follows, 8:30-9pm at treehouse")
        }
        return outcome
    }

    /// What a planned event looks like, in a line: "all hands 5 · ✩ x, mint · thu nov 26 7:30-8:30pm · pigott hall 260-113".
    static func describe(_ plan: EventPlan, calendars: [GCalendar], rules: CalendarRules) -> String {
        let calendar = calendars.first { $0.id == plan.calendarId }
        let label = calendar?.labels.first { $0.id == plan.labelId }?.name
        var parts = [plan.title, (calendar?.name ?? "calendar") + (label.map { ", " + $0 } ?? "")]
        var when = Format.shortDay(plan.day)
        if !plan.allDay, let start = plan.start, let end = plan.end, let from = plan.startDate, let to = plan.endDate {
            when += " " + Format.span(from, to, allDay: false)
            _ = (start, end)
        } else {
            when += ", all day"
        }
        parts.append(when)
        if !plan.location.isEmpty { parts.append(plan.location) }
        return parts.joined(separator: " · ")
    }
}

/// CALENDAR.md: the owner's calendar rules in words, for agents that add to the calendar
/// themselves (and toyl's MCP server, which follows them).
enum CalendarGuide {
    static let text = """
        # calendar rules

        how events go on the google calendar. toyl follows these when it adds anything (its window, `toyl cal add`, and \
        the mcp tool `add_to_calendar`, which checks every rule and says what it still needs). any agent adding events \
        another way should follow them too.

        ## style

        - everything is lowercase: titles, descriptions and locations
        - no em dashes anywhere
        - no "#" in titles: "tic letter 2 due", not "#2"
        - descriptions stay minimal: time and place, at most a free-food note like "no food". no links unless asked. when in doubt, blank
        - the exception is m, which can be more descriptive
        - for events attended for the giveaways, the description lists the free stuff as short item names, one per line

        ## where things go

        sub-calendar first, then a label inside it.

        - ♡ primary: the main calendar
        - ✩ a academic. labels: cs 106b, college 101, pwr 1ju, math 61cm. no label means general school (more coming for next quarter's classes)
        - ✩ c celebrations. holiday label. no label means birthday
        - ✩ e events. music label. no label covers everything else
        - ✩ g fun. culture for movies and shows, food for meals out. no label for other fun, including grocery runs like trader joe's
        - ✩ r reminders. flight and music labels. no label for random reminders, and chores like change sheets and vacuum
        - ✩ v vacations. no labels
        - ✩ x extracurriculars. labels: aasa, treehacks, mint, ssi, smun. no label means other club
        - ✶ m misc. usually hidden. kept deduplicated: nothing sits on m that also exists on another calendar

        ## placement specifics

        - music releases and album drops go on r with the music label, not e
        - the food label on g is for meals out, like lunch with a friend
        - chores such as change sheets and vacuum go on r with no label
        - tentative plans get a "?" in the title with the wording meant, like "hinterland?"
        - mint all-hands is titled "all hands" plus the meeting number, topic in the description, thursdays 7:30-8:30pm at pigott hall 260-113. "margs" follows 8:30-9pm at treehouse. both get the mint label
        - "buy things thursday" is a standing all-day event on r every thursday, skipped in december after the 10th and during breaks

        ## asking, not guessing

        - only add what's actually given. if the date, time or placement is missing, ask instead of guessing
        - a start time without an end: ask how long it should run. there is no standing default length
        - never create new sub-calendars or labels without asking first

        ## reminders and feeds

        - no reminders for calendar events unless asked, and no conflict reminders
        - floor meetings stay out of reminders and rundowns
        - treehacks events can appear twice (the treehacks public calendar is adopted into the owner's own). expected, not a bug
        - the stanford calendar is a scraped feed of on-campus events, also expected

        """

    static var file: URL { Paths.home.appendingPathComponent("CALENDAR.md") }

    static func write() {
        if (try? String(contentsOf: file, encoding: .utf8)) == text { return }
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}
