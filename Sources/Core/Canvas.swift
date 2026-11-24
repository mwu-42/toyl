import Foundation

// Canvas (canvas.stanford.edu, or any school's): your upcoming assignments, quizzes and graded
// discussions, as tasks to get ready for.
// - due when Canvas says, in the list named like the course (else the inbox), linked to Canvas
// - submitted (or marked done) on Canvas: checked off here; its due date moved: moved here
// - one you delete here doesn't come back
// Read with a personal access token (Canvas › account › settings › new access token), which says
// what's been submitted; or, failing that, the calendar feed's address (Canvas › calendar ›
// calendar feed), which doesn't.

/// Whether Canvas is on, which Canvas, and what's been seen. In toyl's folder (`canvas.json`): the
/// token and the feed's address (anyone with them can read your Canvas) are in `Secrets`.
struct CanvasSettings: Codable, Equatable {
    var on = false
    var site = "https://canvas.stanford.edu"
    var lastPull: Date?
    var seen: [String] = []
    /// How far ahead to look.
    var days = 21

    static func load() -> CanvasSettings {
        guard let data = try? Data(contentsOf: Paths.canvas), let settings = try? JSONDecoder.toyl.decode(CanvasSettings.self, from: data) else { return CanvasSettings() }
        return settings
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.toyl.encode(self) { try? data.write(to: Paths.canvas, options: .atomic) }
    }
}

/// One thing due on Canvas.
struct CanvasItem: Equatable {
    let id: String          // "assignment:123"
    let title: String
    let course: String
    let due: Date
    let allDay: Bool
    let url: String?
    /// Submitted, excused, or marked done in Canvas's planner. (The feed can't say: always false.)
    let finished: Bool
}

enum Canvas {
    static var token: String? { Secrets.read("canvas-token").flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 } }
    static var feed: String? { Secrets.read("canvas-feed").flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 } }
    static var isConnected: Bool { token != nil || feed != nil }

    static func setToken(_ token: String) { Secrets.write(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8), "canvas-token") }
    static func setFeed(_ feed: String) { Secrets.write(Data(feed.trimmingCharacters(in: .whitespacesAndNewlines).utf8), "canvas-feed") }

    static func forget() {
        Secrets.delete("canvas-token")
        Secrets.delete("canvas-feed")
    }

    /// "canvas.stanford.edu" or a full address, as an https site without a trailing slash.
    static func site(from text: String) -> String {
        var site = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !site.contains("://") { site = "https://" + site }
        while site.hasSuffix("/") { site.removeLast() }
        return site
    }

    // MARK: - reading

    /// What's due from a few days ago to `days` ahead.
    static func upcoming(_ settings: CanvasSettings, now: Date = Date()) async throws -> [CanvasItem] {
        let from = now.addingTimeInterval(-3 * 86400), to = now.addingTimeInterval(Double(settings.days) * 86400)
        if let token { return try await planner(site: GoogleAuth.env("TOYL_CANVAS") ?? settings.site, token: token, from: from, to: to) }
        if let feed { return try await calendarFeed(feed).filter { $0.due >= from && $0.due <= to } }
        throw GoogleAuth.Failure.said("canvas isn't connected: paste a token or the calendar feed in settings › canvas")
    }

    /// Canvas's planner: assignments, quizzes and discussions, with whether each is submitted.
    static func planner(site: String, token: String, from: Date, to: Date) async throws -> [CanvasItem] {
        var components = URLComponents(string: site + "/api/v1/planner/items")!
        components.queryItems = [URLQueryItem(name: "start_date", value: GoogleTime.utc(from)), URLQueryItem(name: "end_date", value: GoogleTime.utc(to)),
                                 URLQueryItem(name: "per_page", value: "100")]
        var next = components.url
        var found: [CanvasItem] = []
        var pages = 0
        while let url = next, pages < 6 {
            pages += 1
            var request = URLRequest(url: url)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = ((json?["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? "http \(status)"
                throw GoogleAuth.Failure.said(status == 401 ? "canvas turned the token down: make a new one" : "canvas said: " + message.lowercased())
            }
            let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            found += items.compactMap { item(from: $0, site: site) }
            next = nextPage((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link"))
        }
        return found
    }

    static func item(from e: [String: Any], site: String) -> CanvasItem? {
        guard let kind = e["plannable_type"] as? String, ["assignment", "quiz", "discussion_topic", "sub_assignment"].contains(kind) else { return nil }
        let plannable = e["plannable"] as? [String: Any] ?? [:]
        let number = (e["plannable_id"] as? NSNumber)?.stringValue ?? (e["plannable_id"] as? String) ?? ""
        guard !number.isEmpty, let due = GoogleTime.date(plannable["due_at"] ?? e["plannable_date"]) else { return nil }
        let title = (plannable["title"] as? String) ?? (plannable["name"] as? String) ?? "assignment"
        let submissions = e["submissions"] as? [String: Any]
        let finished = submissions?["submitted"] as? Bool == true || submissions?["excused"] as? Bool == true
            || (e["planner_override"] as? [String: Any])?["marked_complete"] as? Bool == true
        let link = (e["html_url"] as? String).map { $0.hasPrefix("http") ? $0 : site + $0 }
        return CanvasItem(id: kind + ":" + number, title: title, course: e["context_name"] as? String ?? "", due: due, allDay: false, url: link, finished: finished)
    }

    /// The next page's address, from a `Link` header.
    static func nextPage(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            if let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">") { return URL(string: String(part[part.index(after: start)..<end])) }
        }
        return nil
    }

    /// The calendar feed (an .ics): its assignments.
    static func calendarFeed(_ address: String) async throws -> [CanvasItem] {
        var address = address
        if address.hasPrefix("webcal://") { address = "https://" + address.dropFirst(9) }
        guard let url = URL(string: address) else { throw GoogleAuth.Failure.said("that isn't a feed's address") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw GoogleAuth.Failure.said("couldn't read the canvas feed")
        }
        return parseFeed(text)
    }

    /// An .ics's assignments (their UIDs say "assignment"), the course from the "[CS 106B]" after the title.
    static func parseFeed(_ text: String) -> [CanvasItem] {
        // Lines folded onto the next, put back together.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
            .split(separator: "\n").map(String.init)
        var items: [CanvasItem] = []
        var event: [String: (params: String, value: String)]?
        for line in lines {
            if line == "BEGIN:VEVENT" { event = [:]; continue }
            if line == "END:VEVENT" {
                if let e = event, let uid = e["UID"]?.value, uid.contains("assignment"), let start = e["DTSTART"], let due = feedDate(start.value, params: start.params) {
                    var title = unescape(e["SUMMARY"]?.value ?? "assignment")
                    var course = ""
                    if let open = title.lastIndex(of: "["), title.hasSuffix("]") {
                        course = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
                        title = title[..<open].trimmingCharacters(in: .whitespaces)
                    }
                    let number = uid.split(whereSeparator: { !$0.isNumber }).last.map(String.init) ?? uid
                    items.append(CanvasItem(id: "assignment:" + number, title: title, course: course, due: due, allDay: start.params.contains("VALUE=DATE"),
                                            url: e["URL"]?.value, finished: false))
                }
                event = nil
                continue
            }
            guard event != nil, let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon]
            let name = head.split(separator: ";").first.map(String.init) ?? ""
            event?[name] = (String(head.dropFirst(name.count)), String(line[line.index(after: colon)...]))
        }
        return items
    }

    static func feedDate(_ value: String, params: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if params.contains("VALUE=DATE") || value.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .autoupdatingCurrent
            return formatter.date(from: value)
        }
        formatter.dateFormat = value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        formatter.timeZone = value.hasSuffix("Z") ? TimeZone(identifier: "UTC") : (params.range(of: "TZID=").flatMap { TimeZone(identifier: String(params[$0.upperBound...]).split(separator: ";").first.map(String.init) ?? "") } ?? .autoupdatingCurrent)
        return formatter.date(from: value)
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: - into toyl

    struct Outcome {
        var added: [String] = []
        var moved: [String] = []
        var done: [String] = []
        var errors: [String] = []
        var seen: [String] = []
        var drafts: [TaskDraft] = []
        var patches: [(id: String, patch: TaskPatch)] = []
        var finish: [String] = []

        var said: String {
            var parts: [String] = []
            if !added.isEmpty { parts.append("\(added.count) from canvas") }
            if !moved.isEmpty { parts.append("\(moved.count) moved") }
            if !done.isEmpty { parts.append("\(done.count) done on canvas") }
            return parts.joined(separator: " · ")
        }
    }

    /// What Canvas's items mean for the list: new tasks for new assignments, due dates that
    /// moved, and ones submitted there to check off. Nothing's changed until it's applied.
    static func plan(_ items: [CanvasItem], snap: Snapshot, settings: CanvasSettings, now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        let seen = Set(settings.seen)
        for item in items {
            outcome.seen.append(item.id)
            let day = Day.string(item.due)
            let time = item.allDay ? nil : Day.clock(item.due)
            let said = day + (time.map { " " + $0 } ?? "")
            if let task = snap.tasks.first(where: { $0.canvas?.id == item.id }), var link = task.canvas {
                guard !task.done else { continue }
                if item.finished {
                    outcome.finish.append(task.id)
                    outcome.done.append(task.title)
                } else if link.due != said {
                    // Canvas's own date changed (or isn't known yet): the task moves only if Canvas
                    // moved it, never back from a day it was moved to here.
                    let moved = link.due != nil && (task.due != day || task.time != time)
                    link.due = said
                    var p = TaskPatch()
                    p.canvas = link
                    if moved {
                        p.due = .some(day)
                        p.time = .some(time)
                        outcome.moved.append(task.title)
                    }
                    outcome.patches.append((task.id, p))
                }
                continue
            }
            guard !seen.contains(item.id), !item.finished, item.due > now.addingTimeInterval(-3 * 86400) else { continue }
            var draft = TaskDraft(title: item.title.lowercased())
            draft.due = day
            draft.time = time
            draft.listId = list(for: item.course, in: snap)?.id ?? ListModel.inbox
            draft.source = "canvas"
            draft.notes = item.url ?? ""
            draft.canvas = CanvasLink(id: item.id, course: item.course, url: item.url, due: said)
            draft.position = .bottom
            outcome.drafts.append(draft)
            outcome.added.append(draft.title)
        }
        return outcome
    }

    /// The list a course belongs in: one named like it ("💻 cs 106b" for "CS 106B: Programming
    /// Abstractions" or "[CS-106B-01]"), letters and numbers alone compared.
    static func list(for course: String, in snap: Snapshot) -> ListModel? {
        let name = squash(course)
        guard !name.isEmpty else { return nil }
        return snap.ownLists.filter { !$0.archived }.first { list in
            let key = squash(list.bareName)
            return key.count >= 3 && name.contains(key)
        }
    }

    private static func squash(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The changes, as one edit of the file.
    static func apply(_ outcome: Outcome, ids: [String], to doc: inout Doc, now: Date = Date()) {
        for (draft, id) in zip(outcome.drafts, ids) { _ = doc.addTask(draft, id: id, now: now) }
        for change in outcome.patches { doc.updateTask(change.id, change.patch, now: now) }
        for id in outcome.finish { doc.setDone(id, true, now: now) }
    }

    /// Remembers what was seen and when.
    static func finish(_ outcome: Outcome, now: Date = Date()) {
        var settings = CanvasSettings.load()
        settings.lastPull = now
        settings.seen = Array((settings.seen + outcome.seen.filter { !settings.seen.contains($0) }).suffix(4000))
        settings.save()
    }
}
