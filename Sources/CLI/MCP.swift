import Foundation

/// toyl's MCP server (the Model Context Protocol, which Claude Desktop, Claude Code, Muse Code and
/// others speak): JSON-RPC, one message a line, on stdin and stdout. Run as `toyl mcp`. Every
/// change is saved at once, as the command line saves it.
enum MCP {
    static let versions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let preferred = "2025-11-25"

    static let instructions = """
        toyl is the user's to-do list (a Mac app; "things off your list"). Call get_overview first to get your bearings. \
        Lists hold tasks (the inbox holds unfiled ones; "ideas" holds loose ideas); tasks have tags, a deadline ("due", \
        YYYY-MM-DD, with an optional 24-hour "time") and/or an aim (a day to have it done by, roughly, which can slip). \
        There are no priorities: what's pressing is what's due; "pinned" keeps a task at the top of today. add_task's \
        "text" understands quick add ("essay draft fri 5pm #cs ~2h"). Refer to tasks by id. Keep the user's own wording \
        and case: don't capitalize or reword their tasks unless asked. Before deleting or bulk-changing, say what you'll do. \
        For Google Calendar, use add_to_calendar: it follows the user's calendar rules (resource toyl://calendar.md: lowercase, \
        no em dashes, no "#" in titles, minimal descriptions, no reminders, sub-calendar then label) and answers with questions \
        when the day, time, end or placement is missing. Ask the user those questions; never guess them.
        """

    static func serve() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) else {
                send(failure(-32700, "parse error", id: NSNull()))
                continue
            }
            if let batch = message as? [Any] {
                let replies = batch.compactMap(handle)
                if !replies.isEmpty { send(replies) }
            } else if let reply = handle(message) {
                send(reply)
            }
        }
        return 0
    }

    private static func send(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data(("toyl mcp: " + text + "\n").utf8))
    }

    static func handle(_ message: Any) -> [String: Any]? {
        guard let m = message as? [String: Any] else { return failure(-32600, "invalid request", id: NSNull()) }
        let id = m["id"]
        // A reply to something we asked (we never do), or a notification: nothing to say.
        guard let method = m["method"] as? String else { return nil }
        let params = m["params"] as? [String: Any] ?? [:]
        let isNotification = id == nil || id is NSNull
        func reply(_ result: [String: Any]) -> [String: Any]? { isNotification ? nil : ["jsonrpc": "2.0", "id": id!, "result": result] }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? preferred
            return reply([
                "protocolVersion": versions.contains(asked) ? asked : preferred,
                "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false, "subscribe": false],
                                 "prompts": ["listChanged": false], "logging": [String: Any]()],
                "serverInfo": ["name": "toyl", "title": "toyl", "version": CLI.version],
                "instructions": instructions,
            ])
        case "ping": return reply([:])
        case "logging/setLevel": return reply([:])
        case "tools/list": return reply(["tools": Tools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return reply(Tools.call(name, arguments))
        case "resources/list":
            return reply(["resources": [
                ["uri": "toyl://list.md", "name": "toyl.md", "title": "the whole list (markdown)", "mimeType": "text/markdown",
                 "description": "every list and open task, with ids, as Markdown"],
                ["uri": "toyl://today.json", "name": "today", "title": "today", "mimeType": "application/json",
                 "description": "what's due, aimed or pinned for today, and today's calendar"],
                ["uri": "toyl://agents.md", "name": "AGENTS.md", "title": "how toyl works", "mimeType": "text/markdown",
                 "description": "how the list is kept, and every way to read and change it"],
                ["uri": "toyl://calendar.md", "name": "CALENDAR.md", "title": "calendar rules", "mimeType": "text/markdown",
                 "description": "how events go on the user's google calendar: style, sub-calendars and labels, what to ask"],
            ]])
        case "resources/templates/list": return reply(["resourceTemplates": [Any]()])
        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            do {
                let text: String, type: String
                switch uri {
                case "toyl://list.md":
                    (text, type) = (Mirror.render(try Actions.doc()), "text/markdown")
                case "toyl://today.json":
                    (text, type) = (Ops.text(try Tools.today()), "application/json")
                case "toyl://agents.md":
                    (text, type) = (AgentDocs.text(), "text/markdown")
                case "toyl://calendar.md":
                    (text, type) = (CalendarGuide.text, "text/markdown")
                default:
                    return isNotification ? nil : failure(-32002, "no resource \(uri)", id: id!)
                }
                return reply(["contents": [["uri": uri, "mimeType": type, "text": text]]])
            } catch {
                return isNotification ? nil : failure(-32603, "\(error)", id: id!)
            }
        case "prompts/list": return reply(["prompts": Prompts.definitions])
        case "prompts/get":
            let name = params["name"] as? String ?? ""
            guard let prompt = Prompts.get(name, params["arguments"] as? [String: Any] ?? [:]) else {
                return isNotification ? nil : failure(-32602, "no prompt \(name)", id: id!)
            }
            return reply(prompt)
        case "completion/complete": return reply(["completion": ["values": [Any](), "hasMore": false]])
        default:
            if method.hasPrefix("notifications/") || isNotification { return nil }
            return failure(-32601, "method not found: \(method)", id: id!)
        }
    }

    private static func failure(_ code: Int, _ message: String, id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}

/// The tools an agent can call.
enum Tools {
    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func nullableString(_ description: String) -> [String: Any] { ["type": ["string", "null"], "description": description] }
    private static func bool(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    private static func strings(_ description: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": description] }

    private static func tool(_ name: String, _ title: String, _ description: String, _ schema: [String: Any],
                             readOnly: Bool = false, destructive: Bool = false, idempotent: Bool = false) -> [String: Any] {
        ["name": name, "title": title, "description": description, "inputSchema": schema,
         "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive, "idempotentHint": idempotent, "openWorldHint": false]]
    }

    static let taskFields: [String: Any] = [
        "title": string("the task's name, kept exactly as given"),
        "notes": string("notes"),
        "list": string("list id or name (\"inbox\", \"ideas\", or one of the user's: a word of its name works, like \"cs\")"),
        "section": string("section id or name within the list"),
        "tags": strings("tags, without #"),
        "due": nullableString("deadline: YYYY-MM-DD or words like \"fri\", \"tomorrow\"; null to clear"),
        "time": nullableString("time on the due day, \"HH:MM\" 24-hour or \"5pm\"; null to clear"),
        "aim": nullableString("aim (a day to have it done by roughly, can slip): YYYY-MM-DD or \"next week\", \"early dec\"; null to clear"),
        "repeat": nullableString("daily, weekdays, weekly, biweekly, monthly or yearly; null to stop"),
        "duration_minutes": ["type": ["integer", "null"], "description": "how long it should take, in minutes"],
        "pinned": bool("kept at the top of today"),
        "someday": bool("put off into ideas (it keeps its list)"),
    ]

    static var definitions: [[String: Any]] {
        var add = taskFields
        add["text"] = string("quick add: the whole task in words, e.g. \"essay draft fri 5pm #cs ~2h\" (#word is a list if one is named so, else a tag; \"by fri\" is an aim; \"!\" pins; \" // \" starts notes). Fields given apart win over what text says.")
        add["subtasks"] = strings("subtasks to add")
        add["idea"] = bool("put it in ideas (loose ideas, to come back to)")
        var update = taskFields
        update["id"] = string("the task's id (or its exact title)")
        update["add_tags"] = strings("tags to add")
        update["remove_tags"] = strings("tags to take off")
        update["add_subtasks"] = strings("subtasks to add")
        update["complete_subtasks"] = strings("subtask ids or titles to tick off")
        update.removeValue(forKey: "tags")
        update["tags"] = strings("replace all its tags with these")
        return [
            tool("get_overview", "overview", "Today's date, counts (due today, late, inbox…), the user's lists and tags, and running timers. Call this first.",
                 object([:]), readOnly: true, idempotent: true),
            tool("list_tasks", "list tasks",
                 "Tasks in a view or matching a filter. Views: today (due/aimed today or late, and pinned), inbox, anytime (all open), ideas (loose ideas and anything put off), upcoming (dated later), logbook (done). Filter words: #tag -#tag in:list due:today|tomorrow|week|month|overdue|soon|none|any|fri before:dec-1 after:fri is:done|all|pinned|someday|repeating|late|slipped has:notes|time|timer, plus plain words.",
                 object(["view": ["type": "string", "enum": ["today", "inbox", "anytime", "ideas", "upcoming", "logbook"]],
                         "query": string("filter, e.g. \"#school due:week\""), "list": string("only this list (id or name)"),
                         "tag": string("only this tag"), "include_done": bool("include done tasks"),
                         "limit": ["type": "integer", "description": "at most this many (default 100)"]]),
                 readOnly: true, idempotent: true),
            tool("get_task", "get a task", "One task, everything about it.", object(["id": string("task id, or its title")], required: ["id"]),
                 readOnly: true, idempotent: true),
            tool("add_task", "add a task", "Adds a task (at the top of its list). Give text (quick add) or title.", object(add)),
            tool("add_tasks", "add several tasks", "Adds several tasks at once, e.g. from a brain dump. Each is as add_task takes it.",
                 object(["tasks": ["type": "array", "items": object(add), "description": "the tasks"]], required: ["tasks"])),
            tool("update_task", "change a task", "Changes what's given about a task; anything left out stays as it is.",
                 object(update, required: ["id"]), idempotent: true),
            tool("complete_task", "check a task off", "Checks a task off (done: false puts it back). A repeating task comes back, due its next time.",
                 object(["id": string("task id or title"), "done": bool("false to put it back (default true)")], required: ["id"]), idempotent: true),
            tool("delete_task", "delete a task", "Deletes a task for good. Prefer complete_task for things that were done.",
                 object(["id": string("task id")], required: ["id"]), destructive: true, idempotent: true),
            tool("list_lists", "list lists", "The lists (with sections, groups and open counts).", object([:]), readOnly: true, idempotent: true),
            tool("create_list", "make a list", "Makes a list (or finds the one with that name).",
                 object(["name": string("its name, as the user would write it"), "group": string("a group to put it in (made if needed)"),
                         "color": string("#rrggbb"), "sections": strings("section names, if it should have several")], required: ["name"])),
            tool("list_tags", "list tags", "Every tag on an open task, most used first.", object([:]), readOnly: true, idempotent: true),
            tool("get_agenda", "agenda", "Day by day from today: tasks due or aimed for each day, and calendar events (Google calendars included, as the app last read them).",
                 object(["days": ["type": "integer", "description": "how many days (default 7)"]]), readOnly: true, idempotent: true),
            tool("start_timer", "start a timer", "Starts a countdown (a focus session; default the task's duration or 25 minutes) or a stopwatch, on a task or on its own. Time on a task adds up on it.",
                 object(["task": string("task id or title"), "label": string("a name, for a timer not on a task"),
                         "minutes": ["type": "number", "description": "length of a countdown"], "stopwatch": bool("count up instead")])),
            tool("stop_timer", "stop a timer", "Stops a timer (by timer id or task), or the latest one; its time goes on its task.",
                 object(["id": string("timer id, or task id/title")])),
            tool("list_timers", "list timers", "Timers going now, and the last ones that ended.", object([:]), readOnly: true, idempotent: true),
            tool("autosort_inbox", "autosort the inbox", "Suggests (or, with apply, makes) a list and tags for each inbox task, learned from where the user's other tasks are.",
                 object(["apply": bool("file them (default: just suggest)")])),
            tool("list_calendars", "list google calendars", "The user's Google calendars: each one's key (♡, a, c, e, g, r, v, x, m), what it's for, its labels, and what no label means. Read toyl://calendar.md for the rules.",
                 object([:]), readOnly: true, idempotent: true),
            tool("suggest_calendar_placement", "where it goes", "Which sub-calendar and label the user's rules put something on, and whether that's settled (sure) or needs asking.",
                 object(["task_id": string("a task's id or title"), "title": string("or just what the event's called")]), readOnly: true, idempotent: true),
            tool("add_to_calendar", "add to google calendar",
                 "Adds an event to the user's Google Calendar, their way: lowercase, no em dashes, no \"#\" in titles, minimal description (blank unless given; no links), no reminders, on a sub-calendar and label from their rules. Mint \"all hands N topic\" fills in itself (thursdays 7:30-8:30pm, pigott hall 260-113, margs after). If anything's missing (day, start, end or length, placement, a label that isn't there) nothing's added and it returns questions: ask the user them, don't guess. There is no default length.",
                 object(["title": string("what it's called (written their way for you)"), "calendar": string("key (a, x, ♡…), name, or what it's for"),
                         "label": string("a label on that calendar, or \"none\""), "day": string("YYYY-MM-DD or words like \"fri\""),
                         "start": string("\"15:00\" or \"3pm\""), "end": string("\"16:00\" or \"4pm\""),
                         "duration_minutes": ["type": "integer", "description": "instead of end"], "all_day": bool("an all-day event"),
                         "location": string("where (lowercase)"), "description": string("minimal: time and place, \"no food\", or a giveaway's free stuff one per line"),
                         "task_id": string("the toyl task it's for (it's then tied to it)"), "tentative": bool("adds \"?\" to the title"),
                         "dry_run": bool("check and describe it without adding")]),
                 idempotent: false),
        ]
    }

    static func call(_ name: String, _ a: [String: Any]) -> [String: Any] {
        do {
            let result = try run(name, a)
            return ["content": [["type": "text", "text": Ops.text(result)]], "structuredContent": result]
        } catch let failure as Ops.Failure {
            return ["content": [["type": "text", "text": failure.description]], "isError": true]
        } catch {
            return ["content": [["type": "text", "text": "\(error)"]], "isError": true]
        }
    }

    private static func run(_ name: String, _ a: [String: Any]) throws -> [String: Any] {
        let now = Date()
        switch name {
        case "get_overview":
            var overview = Ops.overview(try Actions.snapshot(), now: now)
            overview["how"] = "dates YYYY-MM-DD; times 24-hour; due = deadline, aim = soft target; use ids"
            return overview
        case "list_tasks":
            let snap = try Actions.snapshot()
            var place = Place(key: a["view"] as? String ?? "") ?? .anytime
            var query = a["query"] as? String ?? ""
            if let ref = a["list"] as? String, !ref.isEmpty {
                guard let list = Ops.list(ref, in: snap) else { throw Ops.Failure("no list “\(ref)”") }
                if a["view"] == nil { place = .list(list.id) } else { query += " in:\(list.id)" }
            }
            if let tag = a["tag"] as? String, !tag.isEmpty { query += " #" + tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            let includeDone = a["include_done"] as? Bool ?? false
            if a["view"] == nil, a["list"] == nil, !query.isEmpty { place = .search }
            if includeDone, place == .search { query += " is:all" }
            let q = query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Query.parse(query, weekStart: snap.weekStart, now: now)
            let tasks = Views.tasks(for: place, in: snap, query: q, showDone: includeDone, now: now)
            let ordered = Views.groups(tasks, place: place, mode: Views.defaultGroup(place), sort: Views.defaultSort(place), snap: snap, now: now).flatMap(\.tasks)
            let limit = (a["limit"] as? NSNumber)?.intValue ?? 100
            return ["view": place == .search ? "filter" : place.key, "count": ordered.count,
                    "tasks": ordered.prefix(max(limit, 1)).map { Ops.json($0, in: snap, now: now) }]
        case "get_task":
            let snap = try Actions.snapshot()
            let task = try Ops.task(try text(a, "id"), in: snap)
            var out = Ops.json(task, in: snap, now: now)
            if let list = snap.list(task.listId), list.sections.count > 1 { out["list_sections"] = list.sections.map(\.name) }
            return out
        case "add_task":
            let snap = try Actions.snapshot()
            let task = try Actions.add(addRequest(a))
            return ["task": Ops.json(task, in: try Actions.snapshot(), now: now), "note": snap.list(task.listId) == nil ? "made a new list" : "added"]
        case "add_tasks":
            guard let items = a["tasks"] as? [Any], !items.isEmpty else { throw Ops.Failure("no tasks given") }
            var added: [TaskModel] = []
            for item in items {
                guard let fields = item as? [String: Any] else { continue }
                added.append(try Actions.add(addRequest(fields)))
            }
            let snap = try Actions.snapshot()
            return ["added": added.count, "tasks": added.map { Ops.json(snap.task($0.id) ?? $0, in: snap, now: now) }]
        case "update_task":
            var r = Actions.EditRequest()
            r.title = a["title"] as? String
            r.notes = a["notes"] as? String
            r.due = clearable(a, "due")
            r.time = clearable(a, "time")
            r.aim = clearable(a, "aim")
            r.list = a["list"] as? String
            r.section = a["section"] as? String
            r.tags = a["tags"] as? [String]
            r.addTags = a["add_tags"] as? [String] ?? []
            r.removeTags = a["remove_tags"] as? [String] ?? []
            r.pinned = a["pinned"] as? Bool
            r.someday = a["someday"] as? Bool
            r.repeats = clearable(a, "repeat")
            if a.keys.contains("duration_minutes") { r.duration = (a["duration_minutes"] as? NSNumber).map { "\($0.intValue)" } ?? "none" }
            r.addSubtasks = a["add_subtasks"] as? [String] ?? []
            r.checkSubtasks = a["complete_subtasks"] as? [String] ?? []
            let task = try Actions.edit(try text(a, "id"), r)
            return ["task": Ops.json(task, in: try Actions.snapshot(), now: now)]
        case "complete_task":
            let (task, next) = try Actions.complete(try text(a, "id"), done: a["done"] as? Bool ?? true)
            let snap = try Actions.snapshot()
            var out: [String: Any] = ["task": Ops.json(task, in: snap, now: now)]
            if let next { out["next"] = Ops.json(next, in: snap, now: now) }
            return out
        case "delete_task":
            let task = try Actions.delete(try text(a, "id"))
            return ["deleted": task.id, "title": task.title]
        case "list_lists":
            let snap = try Actions.snapshot()
            return ["lists": snap.sidebarOrder.map { Ops.json($0, in: snap) }, "groups": snap.groups.map { ["id": $0.id, "name": $0.name] }]
        case "create_list":
            let list = try Actions.newList(try text(a, "name"), group: a["group"] as? String, color: a["color"] as? String,
                                           sections: a["sections"] as? [String] ?? [])
            return ["list": Ops.json(list, in: try Actions.snapshot())]
        case "list_tags":
            return ["tags": try Actions.snapshot().tags.map { ["name": $0.name, "count": $0.count] }]
        case "get_agenda":
            let snap = try Actions.snapshot()
            let days = (a["days"] as? NSNumber)?.intValue ?? 7
            let updated = Actions.events().updated
            return ["calendar_updated": updated.map(Ops.iso) ?? "never (the toyl app reads the calendar while it's open)",
                    "days": Actions.agenda(snap, days: min(days, 60), now: now).map { day in
                        ["date": day.day, "label": Format.day(day.day, now: now) + " · " + Format.shortDay(day.day),
                         "tasks": day.tasks.map { Ops.json($0, in: snap, now: now) },
                         "events": day.events.map { e -> [String: Any] in
                             var event: [String: Any] = ["title": e.title, "start": Ops.iso(e.start), "end": Ops.iso(e.end), "all_day": e.allDay, "calendar": e.calendar]
                             if let location = e.location, !location.isEmpty { event["location"] = location }
                             return event
                         }] as [String: Any]
                    }]
        case "start_timer":
            let timer = try Actions.startTimer(task: a["task"] as? String, label: a["label"] as? String,
                                               minutes: (a["minutes"] as? NSNumber)?.doubleValue, stopwatch: a["stopwatch"] as? Bool ?? false)
            return ["timer": Ops.json(timer, in: try Actions.snapshot(), now: now)]
        case "stop_timer":
            let stopped = try Actions.stopTimer(a["id"] as? String)
            return ["stopped": stopped.map { ["id": $0.id, "label": $0.label, "worked_seconds": Int($0.worked(at: now))] as [String: Any] }]
        case "list_timers":
            let snap = try Actions.snapshot()
            return ["timers": snap.timers.map { Ops.json($0, in: snap, now: now) },
                    "recent": snap.timerLog.prefix(10).map { ["label": $0.label, "seconds": Int($0.seconds), "ended": Ops.iso($0.ended)] as [String: Any] }]
        case "autosort_inbox":
            let snap = try Actions.snapshot()
            let suggestions = Actions.autosort(snap)
            let apply = a["apply"] as? Bool ?? false
            if apply { _ = try Actions.applyAutosort(suggestions) }
            return ["applied": apply, "suggestions": suggestions.map { s -> [String: Any] in
                var row: [String: Any] = ["task_id": s.task.id, "title": s.task.title]
                if let list = s.list { row["list"] = list.displayName; row["confidence"] = (s.confidence * 100).rounded() / 100 }
                if !s.tags.isEmpty { row["tags"] = s.tags }
                return row
            }]
        case "list_calendars":
            let rules = CalendarRules.load()
            let calendars = try Actions.googleCalendars()
            return ["calendars": calendars.map { Actions.json($0, rules: rules) }, "rules": "toyl://calendar.md"]
        case "suggest_calendar_placement":
            let snap = try Actions.snapshot()
            let rules = CalendarRules.load()
            let ref = (a["task_id"] as? String) ?? (a["title"] as? String) ?? ""
            let task = try? Ops.task(ref, in: snap)
            let placement = rules.place(task?.title ?? ref, list: task.flatMap { snap.list($0.listId) }, tags: task?.tags ?? [])
            var out: [String: Any] = ["sure": placement.sure, "reason": placement.reason]
            if let sub = placement.key.flatMap({ rules.sub($0) }) { out["calendar"] = sub.name; out["key"] = sub.key }
            if let label = placement.label { out["label"] = label }
            if !placement.sure { out["ask"] = "ask the user which calendar (and label) it goes on" }
            return out
        case "add_to_calendar":
            var request = EventRequest()
            request.title = a["title"] as? String ?? ""
            request.calendar = a["calendar"] as? String
            request.label = a["label"] as? String
            request.day = a["day"] as? String
            request.start = a["start"] as? String
            request.end = a["end"] as? String
            request.minutes = (a["duration_minutes"] as? NSNumber)?.intValue
            request.allDay = a["all_day"] as? Bool ?? false
            request.location = a["location"] as? String ?? ""
            request.description = a["description"] as? String ?? ""
            request.taskId = a["task_id"] as? String
            request.tentative = a["tentative"] as? Bool ?? false
            let rules = CalendarRules.load()
            let result = try Actions.addToCalendar(request, apply: !(a["dry_run"] as? Bool ?? false))
            var out: [String: Any] = ["added": !result.added.isEmpty, "notes": result.outcome.notes]
            if !result.outcome.questions.isEmpty {
                out["questions"] = result.outcome.questions
                out["next"] = "ask the user these, then call add_to_calendar again with the answers"
            }
            out["events"] = result.added.map { Actions.json($0, calendars: result.calendars) }
            if result.added.isEmpty, result.outcome.questions.isEmpty {
                out["would_add"] = result.outcome.plans.map { CalendarPlanner.describe($0, calendars: result.calendars, rules: rules) }
            }
            return out
        default:
            throw Ops.Failure("no tool called \(name)")
        }
    }

    /// Today, for the resource.
    static func today() throws -> [String: Any] {
        let snap = try Actions.snapshot()
        let now = Date()
        let day = Actions.agenda(snap, days: 1, now: now).first
        return ["date": Day.today(now), "tasks": (day?.tasks ?? []).map { Ops.json($0, in: snap, now: now) },
                "events": (day?.events ?? []).map { ["title": $0.title, "start": Ops.iso($0.start), "end": Ops.iso($0.end), "all_day": $0.allDay] as [String: Any] }]
    }

    private static func addRequest(_ a: [String: Any]) throws -> Actions.AddRequest {
        var r = Actions.AddRequest(source: "mcp")
        r.text = a["text"] as? String
        r.title = a["title"] as? String
        r.notes = a["notes"] as? String
        r.list = a["list"] as? String
        r.section = a["section"] as? String
        r.tags = a["tags"] as? [String] ?? []
        r.due = a["due"] as? String
        r.time = a["time"] as? String
        r.aim = a["aim"] as? String
        r.repeats = a["repeat"] as? String
        r.duration = (a["duration_minutes"] as? NSNumber).map { "\($0.intValue)" }
        r.pinned = a["pinned"] as? Bool
        r.someday = a["someday"] as? Bool
        r.idea = a["idea"] as? Bool ?? false
        r.subtasks = a["subtasks"] as? [String] ?? []
        if (r.text ?? "").isEmpty && (r.title ?? "").isEmpty { throw Ops.Failure("give text (quick add) or a title") }
        return r
    }

    private static func text(_ a: [String: Any], _ key: String) throws -> String {
        guard let value = a[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else { throw Ops.Failure("\(key) is needed") }
        return value
    }

    /// A field that can be set or, with null, cleared: "none" for null.
    private static func clearable(_ a: [String: Any], _ key: String) -> String? {
        guard a.keys.contains(key) else { return nil }
        return a[key] as? String ?? "none"
    }
}

/// Ready-made requests, offered as slash commands in clients that show them.
enum Prompts {
    static let definitions: [[String: Any]] = [
        ["name": "plan_my_day", "title": "plan my day", "description": "Look over today's tasks and calendar and suggest an order to do them in."],
        ["name": "weekly_review", "title": "weekly review", "description": "Go over what's late, slipped, stale or unfiled, and tidy the list."],
        ["name": "brain_dump", "title": "brain dump", "description": "Turn a messy list of thoughts into tasks.",
         "arguments": [["name": "text", "description": "everything on your mind", "required": true]]],
    ]

    static func get(_ name: String, _ arguments: [String: Any]) -> [String: Any]? {
        let text: String
        switch name {
        case "plan_my_day":
            text = """
                Using toyl, plan my day. Call get_overview, list_tasks with view "today", and get_agenda with days 1. \
                Then suggest an order to do things in around my calendar events, with rough times, using each task's \
                duration where it has one. Point out anything late, and anything that won't fit and could move. \
                Don't change anything until I say so; then you can set times with update_task.
                """
        case "weekly_review":
            text = """
                Using toyl, help me do a weekly review. Look at: late tasks (list_tasks query "is:late"), slipped aims \
                ("is:slipped"), the inbox (view "inbox", and autosort_inbox for suggestions), ideas older than a month \
                ("is:stale"), and what's coming up next week (view "upcoming"). Go through them with me a few at a time, \
                suggesting for each: do, reschedule, file, put off to someday, or drop. Make the changes I agree to.
                """
        case "brain_dump":
            let dump = arguments["text"] as? String ?? ""
            text = """
                Turn this brain dump into toyl tasks. Call list_lists first to see my lists, then add_tasks once with \
                every task, keeping my own words (lower case as I wrote them), putting each in the list it belongs in \
                (or the inbox if unsure), with deadlines only where I gave a day, aims for vague timings ("next week"), \
                and loose ideas as ideas. Then tell me what you added.

                \(dump)
                """
        default:
            return nil
        }
        return ["description": definitions.first { $0["name"] as? String == name }?["description"] ?? "",
                "messages": [["role": "user", "content": ["type": "text", "text": text]]]]
    }
}
