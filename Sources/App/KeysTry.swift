import AppKit
import SwiftUI

/// `toyl __keys`: the window built off screen (never shown, nothing brought forward) and keys
/// pressed in it, the way the window's own key watcher takes them, checking what each one does:
/// Return to a new task, typing, adding, editing titles, the arrows, Escape, the sublist and the
/// + line, renaming. Only with a `TOYL_HOME` list. Prints each check; fails if any does.
enum KeysTry {
    static func run(_ arguments: [String]) -> Int32 {
        guard !Paths.isReal else {
            FileHandle.standardError.write(Data("toyl: __keys needs TOYL_HOME\n".utf8))
            return 2
        }
        return MainActor.assumeIsolated { Run().go() }
    }

    @MainActor
    final class Run {
        let model: AppModel
        let window: NSWindow
        var quickEntries = 0
        var failed = 0

        init() {
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

            return finish()
        }

        func finish() -> Int32 {
            print(failed == 0 ? "all good" : "\(failed) failed")
            return failed == 0 ? 0 : 1
        }
    }
}
