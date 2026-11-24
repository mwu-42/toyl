import AppKit
import SwiftUI

/// `toyl __keys`: the window built off screen (never shown, nothing brought forward) and keys
/// pressed in it, the way the window's own key watcher takes them, checking what each one does:
/// Return to a new task, typing, adding, editing titles, the arrows, Escape, the sublist and the
/// + line, renaming, slash words. Only with a `TOYL_HOME` list. Prints each check; fails if any does.
/// `toyl __keys picture.png` also draws the window as "/list groceries" is being typed.
enum KeysTry {
    static func run(_ arguments: [String]) -> Int32 {
        guard !Paths.isReal else {
            FileHandle.standardError.write(Data("toyl: __keys needs TOYL_HOME\n".utf8))
            return 2
        }
        return MainActor.assumeIsolated { Run(arguments: arguments).go() }
    }

    @MainActor
    final class Run {
        let model: AppModel
        let window: NSWindow
        var quickEntries = 0
        var failed = 0
        let arguments: [String]

        init(arguments: [String]) {
            self.arguments = arguments
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            NSApp.appearance = NSAppearance(named: .aqua)
            let store = Store()
            let timers = TimerEngine(store: store)
            let calendar = CalendarBridge(store: store)
            model = AppModel(store: store, timers: timers, calendar: calendar)
            model.place = .anytime
            model.showCalendar = false
            model.showInspector = false
            model.showTasks = true
            model.showSidebar = true
            let size = NSSize(width: 1180, height: 760)
            let view = NSHostingView(rootView: RootView(model: model).frame(width: size.width, height: size.height))
            view.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = view
            Keys.window = window
        }

        func spin(_ seconds: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        func press(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { return }
            // As the window's key watcher, then on to whoever has the keys (as the window sends it).
            if !model.listKey(event, in: window, quickEntry: { self.quickEntries += 1 }, requireKey: false) {
                if let responder = window.firstResponder, responder !== window { responder.keyDown(with: event) }
            }
            spin(0.12)
        }

        func type(_ text: String) { for ch in text { press(String(ch), ch == " " ? 49 : 0) } }
        func enter() { press("\r", 36) }
        func escape() { press("\u{1b}", 53) }
        func down() { press(String(UnicodeScalar(0xF701)!), 125) }
        func up() { press(String(UnicodeScalar(0xF700)!), 126) }
        func backspace() { press("\u{7f}", 51) }
        func tab() { press("\t", 48) }

        var typing: Bool { window.firstResponder is NSText }
        func field(_ name: String) -> InkField? { InkField.named(name) }
        func text(_ name: String) -> String { field(name)?.stringValue ?? "<no field>" }
        func task(_ title: String) -> TaskModel? { model.snap.tasks.first { $0.title == title } }

        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { print("✓ \(what)") } else { failed += 1; print("✗ \(what)  \(detail())") }
        }

        func go() -> Int32 {
            spin(1.0)
            check("nothing has the keys at first", !typing)

            // Return: a new task.
            enter()
            check("Return puts the caret in quick add", field("quick")?.hasKeys == true)
            type("buy milk tmrw")
            check("spaces type into quick add", text("quick") == "buy milk tmrw", text("quick"))
            enter()
            check("Return adds it", task("buy milk") != nil, model.snap.tasks.map(\.title).joined(separator: ", "))
            check("…due tomorrow", task("buy milk")?.due == Day.adding(1, to: Day.today()))
            check("…and stays for the next", field("quick")?.hasKeys == true && text("quick").isEmpty, "\(typing) '\(text("quick"))'")
            type("call mom")
            enter()
            check("a second one, straight after", task("call mom") != nil)
            check("…not editing the one just added", model.editing == nil && field("quick")?.hasKeys == true)
            tab()
            check("Tab with nothing to finish stays in quick add", field("quick")?.hasKeys == true)
            enter()
            check("Return with nothing typed goes back to the list", !typing)

            // Typing with nothing focused.
            type("r")
            check("a letter starts a new task", field("quick")?.hasKeys == true && text("quick") == "r", "'\(text("quick"))'")
            type("ead ch 3")
            check("…and the rest follows", text("quick") == "read ch 3", text("quick"))
            escape()
            check("Escape clears it", text("quick").isEmpty && field("quick")?.hasKeys == true)
            escape()
            check("Escape again lets go", !typing)

            // The arrows.
            escape()
            let visible = model.visible
            down()
            check("↓ selects the first task", model.selection == [visible.first?.id ?? "-"], "\(model.selection) \(visible.map(\.title))")
            down()
            check("↓ again, the next", visible.count < 2 || model.selection == [visible[1].id])
            up()
            check("↑ back", model.selection == [visible.first?.id ?? "-"])
            up()
            check("↑ from the first goes into quick add", field("quick")?.hasKeys == true && model.selection.isEmpty)
            down()
            check("↓ from quick add goes to the list", !typing && model.selection == [visible.first?.id ?? "-"])
            escape()
            check("Escape lets go of the selection", model.selection.isEmpty)

            // Editing a title (⌘E or a double-click).
            guard let milk = task("buy milk"), let mom = task("call mom") else { return finish() }
            model.select(milk.id)
            model.editing = milk.id
            spin(0.4)
            check("editing a title: the caret's in it", field("title")?.hasKeys == true, "\(typing)")
            check("…with the title in it", text("title") == "buy milk", text("title"))
            let range = field("title")?.currentEditor()?.selectedRange
            check("…caret at the end", range == NSRange(location: 8, length: 0), "\(String(describing: range))")
            type(" and eggs")
            enter()
            check("Return keeps the new title", model.snap.task(milk.id)?.title == "buy milk and eggs", model.snap.task(milk.id)?.title ?? "")
            check("…and lets go", !typing && model.editing == nil)
            enter()
            check("Return then starts a new task (not editing the selected one)", field("quick")?.hasKeys == true && model.editing == nil)
            escape()

            model.editing = milk.id
            spin(0.4)
            type("!")
            model.select(mom.id) // a click on another task
            model.leaveTyping()
            spin(0.4)
            check("clicking another task keeps what was typed", model.snap.task(milk.id)?.title == "buy milk and eggs!", model.snap.task(milk.id)?.title ?? "")

            model.editing = mom.id
            spin(0.4)
            type(" back")
            escape()
            check("Escape doesn't keep it", model.snap.task(mom.id)?.title == "call mom" && !typing)

            model.editing = mom.id
            spin(0.4)
            type("x")
            down()
            check("↓ while editing keeps it and moves on", model.snap.task(mom.id)?.title == "call momx" && !typing && model.editing == nil)

            // Space: the description.
            model.select(mom.id)
            let shown = model.showInspector
            type(" ")
            check("space shows the description", model.showInspector != shown)
            spin(0.4)
            if model.showInspector, let detail = field("detail-title") {
                detail.takeKeys()
                spin(0.1)
                type(" soon")
                var p = TaskPatch()
                p.notes = "changed elsewhere"
                model.store.update(mom.id, "notes", p)
                spin(0.4)
                check("a change elsewhere doesn't wipe a title being typed", text("detail-title") == "call momx soon", text("detail-title"))
                enter()
                check("Return in the description keeps it and lets go", model.snap.task(mom.id)?.title == "call momx soon" && !typing)
            } else {
                check("the description's title is there", false)
            }
            type(" ")
            check("space again hides it", model.showInspector == shown)

            // The + line under a list's heading.
            if let group = model.groups.first(where: { $0.listId != nil && $0.listId != ListModel.inbox }), let list = group.listId {
                withAnimation { model.addingTo = group.id }
                spin(0.5)
                check("+ under a heading: the caret's there", field("under")?.hasKeys == true, "\(typing)")
                type("essay draft")
                enter()
                check("…adds into that list", task("essay draft")?.listId == list, task("essay draft")?.listId ?? "none")
                check("…and stays for another", field("under")?.hasKeys == true && text("under").isEmpty)
                enter()
                spin(0.3)
                check("…Return with nothing typed closes it", model.addingTo == nil && !typing)
            } else {
                check("a list heading to add under", false)
            }

            // A task's sublist.
            withAnimation { model.addingSublist = mom.id }
            spin(0.5)
            check("adding to a sublist: the caret's there", field("sublist")?.hasKeys == true)
            type("find number")
            enter()
            check("…adds to it", model.snap.task(mom.id)?.subtasks.map(\.title) == ["find number"])
            escape()
            spin(0.3)
            check("…Escape closes it", model.addingSublist == nil && !typing)

            // Renaming a list.
            if let list = model.snap.lists.first(where: { !$0.isSpecial && !$0.archived }) {
                model.renaming = "list:" + list.id
                spin(0.5)
                let editor = field("rename")?.currentEditor()
                check("renaming: the caret's there with the name selected",
                      field("rename")?.hasKeys == true && editor?.selectedRange.length == (list.name as NSString).length, "\(String(describing: editor?.selectedRange))")
                type("hw")
                enter()
                spin(0.3)
                check("…typing replaces it and Return keeps it", model.snap.list(list.id)?.name == "hw", model.snap.list(list.id)?.name ?? "")
                check("…and lets go", !typing && model.renaming == nil)
            }

            // The filter.
            model.focusFilter += 1
            spin(0.3)
            type("milk")
            enter()
            check("Return in the filter goes to what it found", !typing && model.selection == [milk.id], "\(model.selection)")
            escape()
            model.filter = ""
            spin(0.2)

            // Delete.
            model.select(mom.id)
            backspace()
            spin(0.5)
            check("⌫ deletes what's selected", model.snap.task(mom.id) == nil || model.snap.task(mom.id)?.done == true || !model.visible.contains { $0.id == mom.id })

            // The page hidden: Return opens quick entry.
            model.showTasks = false
            spin(0.3)
            enter()
            check("Return with the page hidden opens quick entry", quickEntries == 1)
            model.showTasks = true
            spin(0.3)

            // Quick entry (⌘⌥X): the caret's there; ⌘Return adds and stays open; Return adds and closes.
            var closed = 0
            let entry = NSWindow(contentRect: NSRect(x: -30000, y: -29000, width: 640, height: 130), styleMask: [.titled],
                                 backing: .buffered, defer: false)
            entry.contentView = NSHostingView(rootView: QuickEntryView(model: model) { closed += 1 })
            spin(0.5)
            check("quick entry: the caret's there", entry.firstResponder is NSText)
            func pressIn(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                   windowNumber: entry.windowNumber, context: nil, characters: chars,
                                                   charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
                // As the window sends it: key equivalents (⌘) to its views first, then to whoever has the keys.
                if flags.contains(.command), entry.contentView?.performKeyEquivalent(with: event) == true { spin(0.12); return }
                if !model.listKey(event, in: window, quickEntry: {}, requireKey: false) { entry.firstResponder?.keyDown(with: event) }
                spin(0.12)
            }
            for ch in "pay rent" { pressIn(String(ch), ch == " " ? 49 : 0) }
            pressIn("\r", 36, .command)
            check("…⌘Return adds and stays open", task("pay rent") != nil && closed == 0, "\(closed)")
            for ch in "water plants" { pressIn(String(ch), ch == " " ? 49 : 0) }
            pressIn("\r", 36)
            check("…Return adds and closes", task("water plants") != nil && closed == 1, "\(closed)")

            // Slash words: something else made instead of a task.
            model.place = .anytime
            spin(0.3)
            enter()
            type("/pro")
            check("/pro: the words it could be show", Quick.commandsStarting(text("quick")).first?.word == "project")
            tab()
            check("…Tab finishes it", text("quick") == "/project ", "'\(text("quick"))'")
            escape()
            type("/list groceries")
            if let picture = arguments.first {
                spin(0.3)
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: picture))
                }
            }
            enter()
            let groceries = model.snap.lists.first { $0.name == "groceries" }
            check("/list groceries makes the list, not a task", groceries != nil && task("/list groceries") == nil && task("groceries") == nil)
            check("…and goes there, still typing", model.place == .list(groceries?.id ?? "-") && field("quick")?.hasKeys == true, "\(model.place)")
            type("eggs")
            enter()
            check("…so the next goes into it", task("eggs")?.listId == groceries?.id)
            type("/project weekly shop")
            enter()
            check("/project makes one in the list you're in", groceries.flatMap { model.snap.list($0.id) }?.projects.map(\.name) == ["weekly shop"])
            type("/timer 15m")
            enter()
            check("/timer 15m alone: just a timer", model.timers.timers.contains { $0.taskId == nil && $0.label == "timer" } && task("/timer 15m") == nil)
            type("/group home")
            enter()
            check("/group makes a group of lists", model.snap.groups.contains { $0.name == "home" })
            type("/filter eggs")
            enter()
            check("/filter saves a filter and shows it", model.snap.filters.contains { $0.query == "eggs" } && { if case .filter = model.place { return true } else { return false } }())
            model.place = .anytime
            spin(0.3)
            enter()
            type("/list")
            enter()
            spin(0.5)
            check("/list alone: a new list, its name ready to type", model.renaming?.hasPrefix("list:") == true && field("rename")?.hasKeys == true, "\(String(describing: model.renaming))")
            type("books")
            enter()
            spin(0.3)
            check("…named", model.snap.lists.contains { $0.name == "books" })

            reordering()
            return finish()
        }

        /// What a drop does (the drags themselves can't be made off screen): tasks, lists, groups,
        /// filters, places, projects, sublist items; and renaming tags and timers.
        func reordering() {
            check("drag kinds read", Drag.kind("toyl:a,b") == "tasks" && Drag.kind("toyl-list:x") == "list" && Drag.kind("hello") == "text"
                  && Drag.pair("toyl-sub:t|s").map { $0.0 == "t" && $0.1 == "s" } == true)

            // Tasks in a list sorted "auto": one dragged above a dated one; the list is sorted by hand from then on.
            let list = model.newList("order", rename: false)
            spin(0.2)
            let a = model.store.add({ var d = TaskDraft(title: "alpha"); d.listId = list; d.due = Day.today(); return d }())
            let b = model.store.add({ var d = TaskDraft(title: "bravo"); d.listId = list; return d }())
            let c = model.store.add({ var d = TaskDraft(title: "charlie"); d.listId = list; return d }())
            model.place = .list(list)
            model.setSort(.auto, for: .list(list))
            spin(0.3)
            func titles() -> [String] { model.visible.map(\.title) }
            check("auto puts the dated one first", titles().first == "alpha", "\(titles())")
            guard let group = model.groups.first(where: { $0.tasks.contains { $0.id == c } }) else { return check("a group", false) }
            model.reorder([c], in: group, before: a)
            spin(0.3)
            check("a task dragged above another goes there", titles() == ["charlie", "alpha", "bravo"], "\(titles())")
            check("…and the list is sorted by hand now", model.sortMode(.list(list)) == .manual && model.banner == "sorted by hand now")
            if let group = model.groups.first(where: { $0.tasks.contains { $0.id == a } }) {
                model.reorder([a], in: group, before: nil)
                spin(0.3)
                check("one dragged below the last goes last", titles() == ["charlie", "bravo", "alpha"], "\(titles())")
            }
            model.store.undoManager.undo()
            spin(0.3)
            check("⌘Z undoes a drag in one step", titles() == ["charlie", "alpha", "bravo"], "\(titles())")

            // Into a project: dropped among a project's tasks, it joins.
            let project = model.newProject(in: list, name: "trip", rename: false)
            model.setProject(project, list: list, for: [b])
            spin(0.3)
            if let inProject = model.groups.first(where: { $0.projectId == project }) {
                model.reorder([c], in: inProject, before: b)
                spin(0.3)
                check("dropped in a project's tasks, it joins the project", model.snap.task(c)?.project == project)
            }

            // Lists: into a group, and in order.
            let snap0 = model.snap
            let group1 = model.newGroup("first", rename: false)
            let group2 = model.newGroup("second", rename: false)
            spin(0.2)
            model.moveList(list, before: nil, group: .some(group1))
            spin(0.2)
            check("a list dropped on a group goes in it", model.snap.list(list)?.group == group1)
            if let other = snap0.ownLists.first(where: { $0.id != list && !$0.archived }) {
                model.moveList(other.id, before: list, group: .some(group1))
                spin(0.2)
                let inGroup = model.snap.ownLists.filter { $0.group == group1 }.map(\.id)
                check("a list dropped above another goes before it, in its group", inGroup == [other.id, list], "\(inGroup)")
            }
            model.moveList(list, before: nil, group: .some(nil))
            spin(0.2)
            check("dropped on \"lists\", out of its group", model.snap.list(list)?.group == nil)
            model.moveGroup(group2, before: group1)
            spin(0.2)
            let groups = model.snap.groups.map(\.id)
            check("groups reorder", (groups.firstIndex(of: group2) ?? 9) < (groups.firstIndex(of: group1) ?? 0))

            // Filters.
            model.store.change("f") { $0.addFilter(name: "one", query: "a", id: "f1"); $0.addFilter(name: "two", query: "b", id: "f2") }
            spin(0.2)
            model.moveFilter("f2", before: "f1")
            spin(0.2)
            let filters = model.snap.filters.map(\.id).filter { $0 == "f1" || $0 == "f2" }
            check("filters reorder", filters == ["f2", "f1"], "\(filters)")

            // The fixed places (and ⌘1–6 with them).
            model.movePlace(.timers, before: .anytime)
            check("places reorder", model.placeOrder.first == .timers && model.placeOrder.count == 6)
            model.movePlace(.timers, before: nil)
            check("…and back", model.placeOrder.last == .timers)

            // Projects in a list.
            let second = model.newProject(in: list, name: "move", rename: false)
            spin(0.2)
            model.moveProject(second, in: list, before: project)
            spin(0.2)
            check("projects reorder", model.snap.list(list)?.projects.map(\.id) == [second, project])

            // Sublist items: within a task, and onto another.
            var p = TaskPatch()
            p.subtasks = [Subtask(title: "one"), Subtask(title: "two"), Subtask(title: "three")]
            model.store.update(a, "s", p)
            spin(0.2)
            let items = model.snap.task(a)?.subtasks ?? []
            if items.count == 3 {
                model.moveSubtask(items[2].id, from: a, to: a, before: items[0].id)
                spin(0.2)
                check("sublist items reorder", model.snap.task(a)?.subtasks.map(\.title) == ["three", "one", "two"])
                model.moveSubtask(items[1].id, from: a, to: b, before: nil)
                spin(0.2)
                check("…and move onto another task", model.snap.task(a)?.subtasks.map(\.title) == ["three", "one"]
                      && model.snap.task(b)?.subtasks.map(\.title) == ["two"])
            }

            // Renaming a tag and a timer.
            var t = TaskPatch()
            t.tags = ["errand"]
            model.store.update(b, "t", t)
            spin(0.2)
            model.renameTag("errand", to: "errands")
            spin(0.2)
            check("renaming a tag changes it on its tasks", model.snap.task(b)?.tags == ["errands"])
            if let timer = model.snap.timers.first {
                model.renameTimer(timer.id, to: "tea")
                spin(0.2)
                check("renaming a timer", model.snap.timers.first { $0.id == timer.id }?.label == "tea")
            }

            // Mixed lists (today): a task keeps its list when dragged.
            let d = model.store.add({ var x = TaskDraft(title: "delta"); x.listId = ListModel.inbox; x.due = Day.today(); return x }())
            model.place = .today
            spin(0.3)
            if let today = model.groups.first(where: { $0.tasks.contains { $0.id == d } }) {
                model.reorder([d], in: today, before: a)
                spin(0.3)
                check("dragged in today, it stays in its own list", model.snap.task(d)?.listId == ListModel.inbox)
            }
        }

        func finish() -> Int32 {
            print(failed == 0 ? "all good" : "\(failed) failed")
            return failed == 0 ? 0 : 1
        }
    }
}
