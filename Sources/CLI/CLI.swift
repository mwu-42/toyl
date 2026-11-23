import Foundation

/// `toyl`, the command line: the list from a terminal, a script, or an agent (Claude Code, Muse
/// Code). Every command can answer in JSON (`--json`).
enum CLI {
    static let commands: Set<String> = [
        "help", "today", "inbox", "upcoming", "anytime", "all", "someday", "logbook", "ideas", "ls", "list", "search", "show",
        "add", "idea", "done", "undo", "undone", "rm", "delete", "edit", "lists", "tags", "new-list", "agenda", "overview",
        "timer", "timers", "autosort", "md", "json", "path", "agents", "open", "mcp", "version", "connect", "google", "cal", "mail", "merge", "canvas",
        "--help", "-h", "--version",
    ]

    /// Whether these arguments are a command (rather than the app being opened).
    static func handles(_ arguments: [String]) -> Bool {
        let launchedFromLink = !(arguments.first ?? "").contains(".app/Contents/MacOS/")
        guard let first = arguments.dropFirst().first else { return launchedFromLink }
        return commands.contains(first) || (launchedFromLink && !first.hasPrefix("-psn"))
    }

    static func run(_ arguments: [String]) -> Int32 {
        var rest = Array(arguments.dropFirst())
        if rest.isEmpty { rest = ["today"] }
        let command = rest.removeFirst()
        let args = Args(rest)
        do {
            switch command {
            case "help", "--help", "-h": print(help)
            case "version", "--version": print("toyl \(version)")
            case "today", "inbox", "upcoming", "anytime", "all", "someday", "logbook", "ideas":
                try show(place: Place(key: command)!, args: args)
            case "ls", "list", "search": try list(args)
            case "show": try showTask(args)
            case "add", "idea": try add(args, idea: command == "idea")
            case "done": try complete(args, done: true)
            case "undo", "undone": try complete(args, done: false)
            case "rm", "delete": try delete(args)
            case "edit": try edit(args)
            case "lists": try lists(args)
            case "tags": try tags(args)
            case "new-list": try newList(args)
            case "agenda": try agenda(args)
            case "overview": out(Ops.overview(try Actions.snapshot()), args, text: Ops.text(Ops.overview(try Actions.snapshot())))
            case "timer", "timers": try timer(args, listOnly: command == "timers")
            case "autosort": try autosort(args)
            case "md": print(Mirror.render(try Actions.doc()), terminator: "")
            case "json": print(String(data: try Actions.doc().data() ?? Data(), encoding: .utf8) ?? "")
            case "path": print(Paths.home.path)
            case "agents":
                AgentDocs.write()
                print(Paths.agents.path)
            case "open": open(args.positional.first)
            case "connect": try connect(args)
            case "google": try google(args)
            case "mail": try mail(args)
            case "merge": try merge(args)
            case "canvas": try canvas(args)
            case "cal":
                switch try cal(args) {
                case .needs: return 3
                case .done: break
                }
            case "mcp": return MCP.serve()
            default:
                // Anything else from the command link: quick add ("toyl buy milk fri").
                try add(Args([command] + rest), idea: false)
            }
            return 0
        } catch let failure as Ops.Failure {
            FileHandle.standardError.write(Data(("toyl: " + failure.description + "\n").utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data(("toyl: \(error.localizedDescription)\n").utf8))
            return 1
        }
    }

    static let version = "0.1"

    // MARK: - looking

    private static func show(place: Place, args: Args) throws {
        let snap = try Actions.snapshot()
        let now = Date()
        let query = args.positional.isEmpty ? nil : Query.parse(args.positional.joined(separator: " "), weekStart: snap.weekStart, now: now)
        let tasks = Views.tasks(for: place, in: snap, query: query, showDone: args.has("done"), now: now)
        let groups = Views.groups(tasks, place: place, mode: Views.defaultGroup(place), sort: Views.defaultSort(place), snap: snap, now: now)
        if args.has("json") {
            print(Ops.text(["view": place.key, "count": tasks.count, "tasks": groups.flatMap(\.tasks).map { Ops.json($0, in: snap, now: now) }]))
            return
        }
        var lines: [String] = []
        if place == .today {
            let events = Actions.agenda(snap, days: 1, now: now).first?.events ?? []
            for event in events { lines.append("   " + Format.span(event.start, event.end, allDay: event.allDay) + "  " + event.title) }
            if !events.isEmpty { lines.append("") }
        }
        for group in groups where !group.tasks.isEmpty {
            if let title = group.title { lines.append(title + (group.subtitle.map { " · " + $0 } ?? "")) }
            for task in group.tasks {
                lines.append("  " + Ops.line(task, in: snap, now: now, showList: !isListPlace(place)))
                lines += Ops.sublist(task)
            }
        }
        print(lines.isEmpty ? "nothing here" : lines.joined(separator: "\n"))
    }

    private static func isListPlace(_ place: Place) -> Bool {
        switch place {
        case .list, .inbox, .ideas: return true
        default: return false
        }
    }

    private static func list(_ args: Args) throws {
        let snap = try Actions.snapshot()
        var text = args.positional.joined(separator: " ")
        if let list = args.value("list") { text += " in:\"\(list)\"" }
        if args.has("done") { text += " is:all" }
        let place: Place = args.value("list").flatMap { Ops.list($0, in: snap) }.map { .list($0.id) } ?? .search
        try show(place: place, args: Args(text.isEmpty ? [] : [text] + (args.has("json") ? ["--json"] : [])))
    }

    private static func showTask(_ args: Args) throws {
        let snap = try Actions.snapshot()
        let task = try Ops.task(args.positional.joined(separator: " "), in: snap)
        if args.has("json") { return print(Ops.text(Ops.json(task, in: snap))) }
        var lines = [Ops.line(task, in: snap)]
        if !task.notes.isEmpty { lines.append(""); lines.append(task.notes) }
        for subtask in task.subtasks { lines.append("  " + (subtask.done ? "[x] " : "[ ] ") + subtask.title + "  (\(subtask.id))") }
        if task.spent > 0 { lines.append("timed: " + Format.spent(task.spent)) }
        print(lines.joined(separator: "\n"))
    }

    private static func lists(_ args: Args) throws {
        let snap = try Actions.snapshot()
        if args.has("json") {
            return print(Ops.text(["lists": snap.sidebarOrder.map { Ops.json($0, in: snap) },
                                   "groups": snap.groups.map { ["id": $0.id, "name": $0.name] }]))
        }
        for list in snap.sidebarOrder {
            let open = snap.tasks.filter { $0.listId == list.id && !$0.done }.count
            let group = list.group.flatMap { id in snap.groups.first { $0.id == id }?.name }
            print("\(list.displayName)\(group.map { "  (\($0))" } ?? "")  \(open)\(list.archived ? "  archived" : "")")
        }
    }

    private static func tags(_ args: Args) throws {
        let snap = try Actions.snapshot()
        if args.has("json") { return print(Ops.text(["tags": snap.tags.map { ["name": $0.name, "count": $0.count] }])) }
        print(snap.tags.isEmpty ? "no tags yet" : snap.tags.map { "#\($0.name)  \($0.count)" }.joined(separator: "\n"))
    }

    private static func agenda(_ args: Args) throws {
        let snap = try Actions.snapshot()
        let days = args.positional.first.flatMap(Int.init) ?? 7
        let now = Date()
        let agenda = Actions.agenda(snap, days: days, now: now)
        if args.has("json") {
            let updated = Actions.events().updated
            print(Ops.text(["calendar_updated": updated.map(Ops.iso) ?? "never (open toyl to read the calendar)",
                            "days": agenda.map { day in
                                ["date": day.day, "label": Format.day(day.day, now: now),
                                 "tasks": day.tasks.map { Ops.json($0, in: snap, now: now) },
                                 "events": day.events.map { e in
                                     ["title": e.title, "start": Ops.iso(e.start), "end": Ops.iso(e.end), "all_day": e.allDay, "calendar": e.calendar]
                                 }] as [String: Any]
                            }]))
            return
        }
        for day in agenda {
            print(Format.day(day.day, now: now) + " · " + Format.shortDay(day.day))
            for event in day.events { print("   " + Format.span(event.start, event.end, allDay: event.allDay) + "  " + event.title) }
            for task in day.tasks { print("  " + Ops.line(task, in: snap, now: now)); Ops.sublist(task).forEach { print($0) } }
            if day.events.isEmpty && day.tasks.isEmpty { print("  nothing") }
        }
    }

    // MARK: - changing

    private static func add(_ args: Args, idea: Bool) throws {
        var request = Actions.AddRequest(source: "cli")
        request.text = args.positional.joined(separator: " ")
        request.title = args.value("title")
        request.notes = args.value("notes")
        request.list = args.value("list")
        request.section = args.value("section")
        request.tags = args.values("tag").flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        request.due = args.value("due")
        request.time = args.value("time")
        request.aim = args.value("aim")
        request.repeats = args.value("repeat")
        request.duration = args.value("duration")
        if args.has("pin") { request.pinned = true }
        if args.has("someday") { request.someday = true }
        request.subtasks = args.values("sub")
        request.idea = idea
        let task = try Actions.add(request)
        let snap = try Actions.snapshot()
        out(Ops.json(task, in: snap), args, text: "added " + Ops.line(task, in: snap))
    }

    private static func complete(_ args: Args, done: Bool) throws {
        guard !args.positional.isEmpty else { throw Ops.Failure("which task? toyl \(done ? "done" : "undo") <id or title>") }
        // Several ids at once, or one title of several words.
        let refs = args.positional.count > 1 && args.positional.allSatisfy({ !$0.contains(" ") && $0.count >= 4 })
            && (try? Actions.snapshot()).map({ snap in args.positional.allSatisfy { ref in snap.task(ref) != nil } }) == true
            ? args.positional : [args.positional.joined(separator: " ")]
        var results: [[String: Any]] = []
        for ref in refs {
            let (task, next) = try Actions.complete(ref, done: done)
            let snap = try Actions.snapshot()
            var result = Ops.json(task, in: snap)
            if let next { result["next"] = Ops.json(next, in: snap) }
            results.append(result)
            if !args.has("json") {
                print((done ? "done " : "back on ") + Ops.line(task, in: snap) + (next.map { "\n  next: " + Ops.line($0, in: snap) } ?? ""))
            }
        }
        if args.has("json") {
            let payload: Any = results.count == 1 ? results[0] : (["tasks": results] as [String: Any])
            print(Ops.text(payload))
        }
    }

    private static func delete(_ args: Args) throws {
        guard !args.positional.isEmpty else { throw Ops.Failure("which task? toyl rm <id or title>") }
        let task = try Actions.delete(args.positional.joined(separator: " "))
        out(["deleted": task.id, "title": task.title], args, text: "deleted “\(task.title)”")
    }

    private static func edit(_ args: Args) throws {
        guard let ref = args.positional.first else { throw Ops.Failure("which task? toyl edit <id or title> --due fri …") }
        var r = Actions.EditRequest()
        r.title = args.value("title")
        r.notes = args.value("notes")
        r.due = args.value("due")
        r.time = args.value("time")
        r.aim = args.value("aim")
        r.list = args.value("list")
        r.section = args.value("section")
        for tag in args.values("tag").flatMap({ $0.split(separator: ",").map(String.init) }) {
            let tag = tag.trimmingCharacters(in: .whitespaces)
            if tag.hasPrefix("-") { r.removeTags.append(String(tag.dropFirst())) }
            else { r.addTags.append(tag.hasPrefix("+") ? String(tag.dropFirst()) : tag) }
        }
        if let tags = args.value("tags") { r.tags = tags.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if args.has("pin") { r.pinned = true }
        if args.has("unpin") { r.pinned = false }
        if args.has("someday") { r.someday = true }
        if args.has("not-someday") { r.someday = false }
        r.repeats = args.value("repeat")
        r.duration = args.value("duration")
        r.addSubtasks = args.values("sub")
        r.checkSubtasks = args.values("check")
        let task = try Actions.edit(args.positional.count > 1 ? args.positional.joined(separator: " ") : ref, r)
        let snap = try Actions.snapshot()
        out(Ops.json(task, in: snap), args, text: "now " + Ops.line(task, in: snap))
    }

    private static func newList(_ args: Args) throws {
        let name = args.positional.joined(separator: " ")
        let list = try Actions.newList(name, group: args.value("group"), color: args.value("color"), sections: args.values("section"))
        out(Ops.json(list, in: try Actions.snapshot()), args, text: "list “\(list.displayName)” (\(list.id))")
    }

    private static func timer(_ args: Args, listOnly: Bool) throws {
        var positional = args.positional
        let action = listOnly ? "list" : (positional.isEmpty ? "list" : positional.removeFirst())
        let now = Date()
        switch action {
        case "start":
            // "toyl timer start essay 25m": the last word, if it's a length, is the length.
            var minutes: Double?
            if let last = positional.last, let read = Ops.minutes(last), let value = read {
                minutes = Double(value)
                positional.removeLast()
            }
            if let value = args.value("minutes").flatMap(Double.init) { minutes = value }
            let ref = positional.joined(separator: " ")
            let snap = try Actions.snapshot()
            let isTask = !ref.isEmpty && (try? Ops.task(ref, in: snap)) != nil
            let timer = try Actions.startTimer(task: isTask ? ref : nil, label: isTask ? nil : (ref.isEmpty ? nil : ref),
                                               minutes: minutes, stopwatch: args.has("stopwatch"))
            out(Ops.json(timer, in: try Actions.snapshot(), now: now), args,
                text: "started “\(timer.label)”" + (timer.kind == .countdown ? " for " + Format.minutes(Int(timer.duration / 60)) : " (stopwatch)"))
        case "stop":
            let stopped = try Actions.stopTimer(positional.joined(separator: " "))
            out(["stopped": stopped.map { ["id": $0.id, "label": $0.label, "worked_seconds": Int($0.worked(at: now))] as [String: Any] }], args,
                text: stopped.map { "stopped “\($0.label)” after " + Format.spent(Int($0.worked(at: now))) }.joined(separator: "\n"))
        default:
            let snap = try Actions.snapshot()
            if args.has("json") {
                return print(Ops.text(["timers": snap.timers.map { Ops.json($0, in: snap, now: now) },
                                       "recent": snap.timerLog.prefix(10).map { ["label": $0.label, "seconds": Int($0.seconds), "ended": Ops.iso($0.ended)] as [String: Any] }]))
            }
            if snap.timers.isEmpty { return print("no timers going") }
            for timer in snap.timers {
                let shown = timer.kind == .countdown ? Format.clock(timer.remaining(at: now)) + " left" : Format.clock(timer.worked(at: now), roundingUp: false)
                print("\(timer.label)  \(shown)\(timer.isRunning ? "" : " (paused)")  (\(timer.id.prefix(8)))")
            }
        }
    }

    private static func autosort(_ args: Args) throws {
        let snap = try Actions.snapshot()
        let suggestions = Actions.autosort(snap)
        let rows = suggestions.map { s -> [String: Any] in
            var row: [String: Any] = ["task_id": s.task.id, "title": s.task.title]
            if let list = s.list { row["list"] = list.displayName; row["confidence"] = (s.confidence * 100).rounded() / 100 }
            if !s.tags.isEmpty { row["tags"] = s.tags }
            return row
        }
        if args.has("apply") { _ = try Actions.applyAutosort(suggestions) }
        if args.has("json") { return print(Ops.text(["applied": args.has("apply"), "suggestions": rows])) }
        if suggestions.isEmpty { return print("nothing in the inbox toyl can place yet") }
        for s in suggestions {
            var said = "“\(s.task.title)”"
            if let list = s.list { said += " → \(list.displayName) (\(Int(s.confidence * 100))%)" }
            if !s.tags.isEmpty { said += " " + s.tags.map { "#" + $0 }.joined(separator: " ") }
            print(said)
        }
        if !args.has("apply") { print("\ntoyl autosort --apply to file them") }
    }

    // MARK: - google calendar

    /// Signing in: `toyl google client <json file, or id and secret>`, `toyl google connect`,
    /// `toyl google disconnect`, `toyl google` (how it stands).
    private static func google(_ args: Args) throws {
        var words = args.positional
        let what = words.isEmpty ? "status" : words.removeFirst()
        switch what {
        case "client":
            var text = words.joined(separator: " ")
            if let id = args.value("id"), let secret = args.value("secret") { text = id + " " + secret }
            if FileManager.default.fileExists(atPath: (text as NSString).expandingTildeInPath),
               let file = try? String(contentsOfFile: (text as NSString).expandingTildeInPath, encoding: .utf8) { text = file }
            guard let client = GoogleAuth.client(from: text) else {
                throw Ops.Failure("that doesn't read as a google oauth client: give the downloaded json file, or --id and --secret")
            }
            GoogleAuth.setClient(client)
            print("client saved (in toyl-private, readable by you alone). now: toyl google connect")
        case "connect":
            let browser = !args.has("no-browser")
            try waitFor {
                try await GoogleAuth.signIn { url in
                    if browser {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        process.arguments = [url.absoluteString]
                        try? process.run()
                        print("finish signing in in your browser…")
                    } else {
                        print(url.absoluteString)
                    }
                    fflush(stdout)
                }
            }
            print("connected to google calendar")
        case "disconnect":
            GoogleAuth.signOut()
            print("signed out of google calendar (the client's kept)")
        default:
            let status = GoogleAuth.client == nil ? "no oauth client yet (toyl google client <json>)" : GoogleAuth.isConnected ? "connected" : "signed out (toyl google connect)"
            if args.has("json") { return print(Ops.text(["client": GoogleAuth.client != nil, "connected": GoogleAuth.isConnected])) }
            print("google calendar: " + status)
        }
    }

    /// Canvas: `toyl canvas` (how it's set), `toyl canvas pull [--dry-run]`, `toyl canvas token <t>`,
    /// `toyl canvas feed <address>`, `toyl canvas site <canvas.school.edu>`, `toyl canvas on|off|forget`.
    private static func canvas(_ args: Args) throws {
        var words = args.positional
        let what = words.isEmpty ? "status" : words.removeFirst()
        var settings = CanvasSettings.load()
        switch what {
        case "pull":
            let outcome = try Actions.pullCanvas(apply: !args.has("dry-run"))
            if args.has("json") {
                return print(Ops.text(["added": outcome.added, "moved": outcome.moved, "done": outcome.done, "errors": outcome.errors]))
            }
            for error in outcome.errors { print("✕ " + error) }
            let verb = args.has("dry-run") ? "would add" : "added"
            for title in outcome.added { print("\(verb): \(title)") }
            for title in outcome.moved { print("moved: \(title)") }
            for title in outcome.done { print("done on canvas: \(title)") }
            if outcome.errors.isEmpty, outcome.added.isEmpty, outcome.moved.isEmpty, outcome.done.isEmpty { print("nothing new from canvas") }
        case "token":
            guard let token = words.first else { throw Ops.Failure("toyl canvas token <token>") }
            Canvas.setToken(token)
            settings.on = true
            settings.save()
            print("canvas token saved (in toyl-private). now: toyl canvas pull")
        case "feed":
            guard let feed = words.first else { throw Ops.Failure("toyl canvas feed <address>") }
            Canvas.setFeed(feed)
            settings.on = true
            settings.save()
            print("canvas feed saved (in toyl-private). now: toyl canvas pull")
        case "site":
            guard let site = words.first else { throw Ops.Failure("toyl canvas site <canvas.school.edu>") }
            settings.site = Canvas.site(from: site)
            settings.save()
            print("canvas: " + settings.site)
        case "on", "off":
            settings.on = what == "on"
            settings.save()
            print("canvas " + what)
        case "forget":
            Canvas.forget()
            settings.on = false
            settings.save()
            print("canvas forgotten")
        default:
            let how = Canvas.token != nil ? "a token" : Canvas.feed != nil ? "its calendar feed" : "nothing yet (toyl canvas token <t>)"
            if args.has("json") { return print(Ops.text(["on": settings.on, "site": settings.site, "connected": Canvas.isConnected])) }
            print("canvas: \(settings.on ? "on" : "off") · \(settings.site) · by \(how)")
            print("last pulled: " + (settings.lastPull.map { GoogleTime.string($0) } ?? "never"))
        }
    }

    /// `toyl merge <list> [into]`: one list folded into another (the inbox, if none's named): its
    /// tasks move over and the list goes.
    private static func merge(_ args: Args) throws {
        let snap = try Actions.snapshot()
        guard let ref = args.positional.first, let from = Ops.list(ref, in: snap) else { throw Ops.Failure("which list? toyl merge <list> [into]") }
        let into = try args.positional.dropFirst().first.map { name -> ListModel in
            guard let list = Ops.list(name, in: snap) else { throw Ops.Failure("no list called “\(name)”") }
            return list
        } ?? snap.list(ListModel.inbox)!
        guard from.id != into.id, from.id != ListModel.inbox, from.id != ListModel.dump else { throw Ops.Failure("can't fold \(from.displayName) into \(into.displayName)") }
        let moving = snap.tasks.filter { $0.listId == from.id }.count
        _ = try Actions.save { $0.mergeList(from.id, into: into.id) }
        out(["merged": from.displayName, "into": into.displayName, "tasks": moving], args,
            text: "folded \(from.displayName) into \(into.displayName) (\(moving) task\(moving == 1 ? "" : "s"))")
    }

    /// Pulling important email: `toyl mail` (how it's set), `toyl mail pull [--dry-run]`,
    /// `toyl mail gmail on|off`, `toyl mail outlook client <id> [tenant]|connect|disconnect|on|off`,
    /// `toyl mail ask on|off`.
    private static func mail(_ args: Args) throws {
        var words = args.positional
        let what = words.isEmpty ? "status" : words.removeFirst()
        var settings = MailSettings.load()
        func onOff() throws -> Bool {
            guard let word = words.first?.lowercased(), ["on", "off", "yes", "no", "true", "false"].contains(word) else { throw Ops.Failure("say on or off") }
            return ["on", "yes", "true"].contains(word)
        }
        switch what {
        case "pull":
            let outcome = try Actions.pullMail(apply: !args.has("dry-run"))
            if args.has("json") {
                print(Ops.text(["looked": outcome.looked, "errors": outcome.errors, "found": outcome.found.map { found -> [String: Any] in
                    var entry: [String: Any] = ["title": found.title, "why": found.why, "from": found.message.from, "subject": found.message.subject,
                                                "account": found.message.account]
                    if let due = found.due { entry["due"] = due }
                    return entry
                }]))
                return
            }
            for error in outcome.errors { print("✕ " + error) }
            if outcome.found.isEmpty {
                print(outcome.seen.isEmpty ? "nothing new" : "nothing important in \(outcome.seen.count) new message\(outcome.seen.count == 1 ? "" : "s")")
            }
            for found in outcome.found {
                print((args.has("dry-run") ? "would add: " : "added: ") + found.title + (found.due.map { " · due " + Format.day($0) } ?? "")
                      + "  (✉ " + found.message.from.lowercased() + ")")
            }
        case "gmail":
            settings.gmail = try onOff()
            if settings.gmail { settings.lastPull = nil }
            settings.save()
            if settings.gmail, !GoogleAuth.allows(Gmail.scope) { print("gmail on. now: toyl google connect (to allow reading mail)") } else { print("gmail " + (settings.gmail ? "on" : "off")) }
        case "ask":
            settings.ask = try onOff()
            settings.save()
            print("apple intelligence " + (settings.ask ? "asked too" : "not asked"))
        case "outlook":
            let sub = words.isEmpty ? "status" : words.removeFirst()
            switch sub {
            case "client":
                guard let client = Outlook.client(from: words.joined(separator: " ")) else { throw Ops.Failure("that isn't an app's client id (a guid from entra)") }
                Outlook.setClient(client)
                print("outlook app saved (in toyl-private, readable by you alone). now: toyl mail outlook connect")
            case "connect":
                let browser = !args.has("no-browser")
                try waitFor {
                    try await Outlook.signIn { url in
                        if browser {
                            let process = Process()
                            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                            process.arguments = [url.absoluteString]
                            try? process.run()
                            print("finish signing in in your browser…")
                        } else {
                            print(url.absoluteString)
                        }
                        fflush(stdout)
                    }
                }
                settings = MailSettings.load()
                settings.outlook = true
                settings.lastPull = nil
                settings.save()
                print("connected to outlook")
            case "disconnect":
                Outlook.signOut()
                settings.outlook = false
                settings.save()
                print("signed out of outlook (the app's kept)")
            case "on", "off":
                settings.outlook = sub == "on"
                if settings.outlook { settings.lastPull = nil }
                settings.save()
                print("outlook " + sub)
            default:
                print("outlook: " + (Outlook.client == nil ? "no app yet (toyl mail outlook client <id>)" : Outlook.isConnected ? "connected" : "signed out (toyl mail outlook connect)"))
            }
        default:
            let status: [String: Any] = ["gmail": settings.gmail, "gmailAllowed": GoogleAuth.allows(Gmail.scope), "outlook": settings.outlook,
                                         "outlookConnected": Outlook.isConnected, "ask": settings.ask,
                                         "lastPull": settings.lastPull.map { GoogleTime.string($0) } ?? NSNull()]
            if args.has("json") { return print(Ops.text(status)) }
            print("gmail: " + (settings.gmail ? (GoogleAuth.allows(Gmail.scope) ? "on" : "on, but google needs connecting again") : "off"))
            print("outlook: " + (settings.outlook ? (Outlook.isConnected ? "on" : "on, but not connected") : "off"))
            print("last pulled: " + (settings.lastPull.map { GoogleTime.string($0) } ?? "never"))
        }
    }

    enum CalResult { case done, needs }

    /// Google Calendar: `toyl cal` (your calendars and labels), `toyl cal suggest <task or
    /// title>`, `toyl cal add <title> --cal a --label "cs 106b" --day fri --start 3pm --end 4pm`.
    private static func cal(_ args: Args) throws -> CalResult {
        var words = args.positional
        let what = words.isEmpty ? "calendars" : words.removeFirst()
        let rules = CalendarRules.load()
        switch what {
        case "suggest", "where":
            let snap = try Actions.snapshot()
            let ref = words.joined(separator: " ")
            let task = try? Ops.task(ref, in: snap)
            let placement = rules.place(task?.title ?? ref, list: task.flatMap { snap.list($0.listId) }, tags: task?.tags ?? [])
            let sub = placement.key.flatMap { rules.sub($0) }
            if args.has("json") {
                var out: [String: Any] = ["sure": placement.sure, "reason": placement.reason]
                if let sub { out["calendar"] = sub.name; out["key"] = sub.key }
                if let label = placement.label { out["label"] = label }
                print(Ops.text(out))
            } else if let sub, placement.sure {
                print("\(sub.name)" + (placement.label.map { ", \($0)" } ?? ", no label") + "  (\(placement.reason))")
            } else {
                print("not sure: " + placement.reason + (placement.label.map { " (\($0)?)" } ?? ""))
            }
            return .done
        case "add":
            var request = EventRequest()
            request.title = words.joined(separator: " ")
            request.calendar = args.value("cal") ?? args.value("calendar")
            request.label = args.value("label")
            request.day = args.value("day") ?? args.value("date")
            request.start = args.value("start") ?? args.value("from")
            request.end = args.value("end") ?? args.value("to")
            request.minutes = args.value("for").flatMap { Ops.minutes($0).flatMap { $0 } }
            request.allDay = args.has("all-day")
            request.location = args.value("where") ?? args.value("location") ?? ""
            request.description = args.value("description") ?? args.value("notes") ?? ""
            request.taskId = args.value("task")
            request.tentative = args.has("tentative")
            request.margs = !args.has("no-margs")
            let result = try Actions.addToCalendar(request, apply: !args.has("dry-run"))
            let outcome = result.outcome
            if args.has("json") {
                print(Ops.text(["added": !result.added.isEmpty, "questions": outcome.questions, "notes": outcome.notes,
                                "events": result.added.map { Actions.json($0, calendars: result.calendars) },
                                "would_add": outcome.plans.map { CalendarPlanner.describe($0, calendars: result.calendars, rules: rules) }]))
            } else {
                for question in outcome.questions { print("? " + question) }
                if outcome.questions.isEmpty {
                    for plan in outcome.plans {
                        print((result.added.isEmpty ? "would add " : "added ") + CalendarPlanner.describe(plan, calendars: result.calendars, rules: rules))
                    }
                }
                for note in outcome.notes { print("  " + note) }
            }
            return outcome.questions.isEmpty ? .done : .needs
        default:
            let calendars = try Actions.googleCalendars()
            if args.has("json") { print(Ops.text(["calendars": calendars.map { Actions.json($0, rules: rules) }])); return .done }
            for calendar in calendars {
                let sub = rules.sub(for: calendar)
                var line = calendar.name + (sub.map { "  " + $0.about } ?? "")
                let labels = calendar.labels.map(\.name).filter { !$0.isEmpty }
                if !labels.isEmpty { line += "  · labels: " + labels.joined(separator: ", ") }
                if let none = sub?.none { line += "  · no label: " + none }
                if !calendar.writable { line += "  (read only)" }
                print(line)
            }
            return .done
        }
    }

    /// Links toyl's MCP server into an agent (as settings › agents and ai does), or says what's linked.
    private static func connect(_ args: Args) throws {
        let what = args.positional.first ?? "status"
        switch what {
        case "claude-desktop", "claude":
            try Integrations.connectClaudeDesktop()
            print("linked to claude desktop (reopen claude to see toyl's tools)")
        case "claude-code":
            try Integrations.connectClaudeCode()
            print("linked to claude code")
        case "muse-code", "muse":
            try Integrations.connectMuseCode()
            print("linked to muse code")
        case "command":
            try Integrations.installCommand()
            print("`toyl` is in ~/.local/bin")
        default:
            let rows: [(String, Bool)] = [("claude desktop", Integrations.claudeDesktopConnected), ("claude code", Integrations.claudeCodeConnected),
                                          ("muse code", Integrations.museCodeConnected), ("the toyl command", Integrations.commandInstalled)]
            if args.has("json") { return print(Ops.text(Dictionary(uniqueKeysWithValues: rows.map { ($0.0, $0.1) }))) }
            for (name, linked) in rows { print("\(name): \(linked ? "linked" : "not linked")") }
            print("\ntoyl connect claude-desktop | claude-code | muse-code | command")
        }
    }

    private static func open(_ place: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let app = Paths.installedApp.path
        process.arguments = place.map { ["toyl://show/" + $0] } ?? (FileManager.default.fileExists(atPath: app) ? [app] : ["-b", "local.toyl"])
        try? process.run()
        process.waitUntilExit()
    }

    /// JSON with --json, else the line of text.
    private static func out(_ json: Any, _ args: Args, text: String) {
        print(args.has("json") ? Ops.text(json) : text)
    }

    static let help = """
        toyl: things off your list

          toyl                         what's on today
          toyl all|today|inbox|ideas [filter]   (and upcoming, logbook)
          toyl mail [pull [--dry-run]|gmail on|off|outlook client <id>|outlook connect|ask on|off]
          toyl merge <list> [into]        fold a list into another (the inbox, if none)
          toyl canvas [pull [--dry-run]|token <t>|feed <address>|site <canvas.school.edu>|on|off|forget]
          toyl ls <filter>             e.g. toyl ls "#school due:week", toyl ls essay is:all
          toyl show <id|title>
          toyl add <text>              e.g. toyl add "essay draft fri 5pm #cs ~2h /timer 25m"
              --list L --section S --tag t --due D --time T --aim A --notes N
              --repeat R --duration 30m --pin --someday --sub "a subtask"
          toyl idea <text>             into ideas
          toyl done|undo|rm <id|title>
          toyl edit <id|title> --title … --due fri --time 5pm --aim "next week" --list cs
              --tag +new --tag -old --tags a,b --pin --unpin --someday --not-someday
              --repeat weekly --duration 45m --notes … --sub "add subtask" --check "subtask"
          toyl lists | tags | agenda [days] | overview
          toyl new-list <name> [--group G] [--color #hex] [--section S]…
          toyl timer start <task|label> [25m] [--stopwatch] | timer stop [id|task] | timers
          toyl autosort [--apply]      file the inbox where it most likely belongs
          toyl google [client <json>|connect|disconnect]   sign in to google calendar
          toyl cal                     your google calendars and their labels
          toyl cal suggest <task|title>   where your calendar rules put it
          toyl cal add <title> --cal a --label "cs 106b" --day fri --start 3pm --end 4pm
              (--for 1h, --all-day, --where, --notes, --task <id>, --tentative, --dry-run)
          toyl connect [claude-desktop|claude-code|muse-code|command]   link toyl's mcp server
          toyl md | json | path | agents | open [place] | mcp | version

          --json on any command for JSON. filters: #tag -#tag in:list due:today|week|overdue|none
          before:dec 1 after:fri is:done|all|pinned|someday|late has:notes|time|timer "a phrase"
        """
}

/// Arguments: words, `--name value` options (some take several), and `--flag`s.
struct Args {
    private(set) var positional: [String] = []
    private var options: [String: [String]] = [:]
    private var flags: Set<String> = []

    static let valued: Set<String> = ["list", "section", "tag", "tags", "due", "time", "aim", "notes", "repeat", "duration", "title",
                                      "group", "color", "sub", "check", "minutes", "cal", "calendar", "label", "day", "date", "start", "from",
                                      "end", "to", "for", "where", "location", "description", "task", "id", "secret"]

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("--"), argument.count > 2 else {
                positional.append(argument)
                continue
            }
            var name = String(argument.dropFirst(2))
            var value: String?
            if let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if Self.valued.contains(name) {
                if value == nil, index < arguments.count {
                    value = arguments[index]
                    index += 1
                }
                options[name, default: []].append(value ?? "")
            } else {
                flags.insert(name)
            }
        }
    }

    func value(_ name: String) -> String? { options[name]?.last }
    func values(_ name: String) -> [String] { options[name] ?? [] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}
