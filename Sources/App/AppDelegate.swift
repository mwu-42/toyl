import AppKit
import Combine
import Carbon
import SwiftUI

/// Opening toyl as an app.
enum ToylApp {
    static func run() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private(set) var model: AppModel!
    private var window: NSWindow!
    private var settings: NSWindow?
    private var quickPanel: QuickEntryPanel?
    private var hotKey: HotKey?
    private var waiting: [URL] = []
    private var roomWatch: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Always on paper: the cream doesn't turn dark.
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = Store()
        let timers = TimerEngine(store: store)
        let calendar = CalendarBridge(store: store)
        model = AppModel(store: store, timers: timers, calendar: calendar)
        NSApp.mainMenu = Menus.build(self)
        makeWindow()
        AgentDocs.write()
        Integrations.installCommandIfNeeded()
        hotKey = HotKey(keyCode: kVK_ANSI_X, modifiers: cmdKey | optionKey, id: 1) { [weak self] in self?.showQuickEntry() }
        handle(waiting)
        waiting = []
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if model == nil { waiting += urls } else { handle(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Remembers whether the window was open, and full screen, and on which display, so an
    /// update (which quits toyl and opens it again) leaves it as it was.
    func applicationWillTerminate(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: "relaunch.at")
        // Still waiting to go back to full screen (never looked at since it opened): as it was.
        if fullScreenWaiting {
            defaults.set(true, forKey: "relaunch.windowOpen")
            return
        }
        let open = window?.isVisible == true && !NSApp.isHidden
        defaults.set(open, forKey: "relaunch.windowOpen")
        defaults.set(open && window?.styleMask.contains(.fullScreen) == true, forKey: "window.fullScreen")
        if let display = window?.screen.flatMap(Self.display) { defaults.set(display, forKey: "window.display") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    // MARK: - full screen, kept across an update

    /// Quit in full screen, opened again: full screen again once toyl's the app in use (you switch
    /// to it), so an update never takes you off what you're doing.
    private var fullScreenWaiting = false
    /// The app that was in use when toyl went back to full screen on another display, to hand
    /// the keys back to.
    private var givingBack: NSRunningApplication?

    func applicationDidBecomeActive(_ notification: Notification) {
        // Not for settings, which opens on its own.
        guard fullScreenWaiting, settings?.isVisible != true else { return }
        showMain()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        // What leaving full screen goes back to, after an update too.
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "window.normalFrame")
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "window.fullScreen")
        if let display = window.screen.flatMap(Self.display) { UserDefaults.standard.set(display, forKey: "window.display") }
        if let app = givingBack {
            givingBack = nil
            if NSApp.isActive {
                NSApp.yieldActivation(to: app)
                app.activate()
            }
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "window.fullScreen")
    }

    /// Back to full screen, on the display it was on. Straight away if that display isn't the
    /// one you're working on (it fills that one, and what you were using keeps the keys);
    /// otherwise once you switch to toyl.
    private func reopenFullScreen() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "window.display") as? UInt32
        let screen = NSScreen.screens.first { Self.display($0) == saved } ?? window.screen ?? NSScreen.main
        if let screen {
            var frame = defaults.string(forKey: "window.normalFrame").map(NSRectFromString) ?? window.frame
            frame.size.width = min(max(frame.width, window.minSize.width), screen.visibleFrame.width)
            frame.size.height = min(max(frame.height, window.minSize.height), screen.visibleFrame.height)
            if !screen.visibleFrame.contains(frame) {
                frame.origin = NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.midY - frame.height / 2)
            }
            window.setFrame(frame, display: false)
        }
        if let screen, let using = Self.screenInUse(), using != screen {
            givingBack = NSWorkspace.shared.frontmostApplication
            enterFullScreen()
        } else {
            fullScreenWaiting = true
        }
    }

    private func enterFullScreen() {
        window.orderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    /// A display's number, which stays the same while it's plugged in.
    private static func display(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The display with the window you're working in (the app in use's front window); nil
    /// when that's toyl.
    private static func screenInUse() -> NSScreen? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let top = NSScreen.screens.first?.frame.height ?? 0
        for info in windows where info[kCGWindowOwnerPID as String] as? pid_t == front.processIdentifier && info[kCGWindowLayer as String] as? Int == 0 {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            // Window bounds count down from the top of the main display; screens count up.
            let middle = NSPoint(x: rect.midX, y: top - rect.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) }) { return screen }
        }
        return NSScreen.main
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model?.store.undoManager }

    private func makeWindow() {
        let hosting = NSHostingController(rootView: RootView(model: model))
        hosting.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "toyl"
        window.backgroundColor = Theme.nsPaper
        window.minSize = NSSize(width: 780, height: 480)
        window.tabbingMode = .disallowed
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1180, height: 760))
        if !window.setFrameUsingName("toyl.main") { window.center() }
        window.setFrameAutosaveName("toyl.main")
        // Opened again straight after quitting (an update): the window as it was then.
        let defaults = UserDefaults.standard
        let relaunched = Date().timeIntervalSince1970 - defaults.double(forKey: "relaunch.at") < 60
        defaults.removeObject(forKey: "relaunch.at")
        if !relaunched || defaults.object(forKey: "relaunch.windowOpen") as? Bool ?? true {
            // Full screen when it was quit: full screen again, on the same display.
            if defaults.bool(forKey: "window.fullScreen") { reopenFullScreen() } else { window.makeKeyAndOrderFront(nil) }
        }
        model.watchSwipes()
        model.watchKeys(in: window) { [weak self] in self?.openQuickEntry() }
        roomWatch = model.$showCalendar.dropFirst().filter { $0 }.map { _ in () }
            .merge(with: model.$calendarMode.dropFirst().map { _ in () })
            .sink { [weak self] _ in DispatchQueue.main.async { self?.makeRoom() } }
        // Nothing has the keys at first (not the filter field, the first a window would pick):
        // Return starts a task, the arrows move through the list.
        DispatchQueue.main.async { [weak self] in self?.window.makeFirstResponder(nil) }
    }

    @objc func showMain() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if fullScreenWaiting {
            fullScreenWaiting = false
            enterFullScreen()
        }
    }

    // MARK: - toyl:// links

    /// toyl://add?text=essay%20fri%205pm (or title=, list=, due=, time=, tags=, notes=),
    /// toyl://task/<id>, toyl://show/today, toyl://search?q=%23school, toyl://quick (quick entry),
    /// toyl://settings
    private func handle(_ urls: [URL]) {
        for url in urls where url.scheme == "toyl" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            switch url.host {
            case "add":
                var request = Actions.AddRequest(source: "link")
                request.text = value("text")
                request.title = value("title")
                request.notes = value("notes")
                request.list = value("list")
                request.due = value("due")
                request.time = value("time")
                request.aim = value("aim")
                request.tags = value("tags")?.split(separator: ",").map(String.init) ?? []
                let snap = model.snap
                var draft: TaskDraft
                if let text = request.text, !text.isEmpty {
                    draft = Quick.parse(text, lists: snap.lists, weekStart: snap.weekStart).draft(source: "link")
                } else if let title = request.title, !title.isEmpty {
                    draft = TaskDraft(title: title)
                    draft.source = "link"
                } else { continue }
                if let notes = request.notes { draft.notes = notes }
                if let ref = request.list, let list = Ops.list(ref, in: snap) { draft.listId = list.id }
                if let due = request.due, let day = Ops.day(due, weekStart: snap.weekStart) { draft.due = day }
                if let time = request.time, let clock = Ops.time(time) { draft.time = clock }
                if let aim = request.aim, let day = Ops.aim(aim, weekStart: snap.weekStart) { draft.target = day }
                draft.tags = TaskModel.tags(draft.tags + request.tags)
                let id = model.store.add(draft)
                model.selection = [id]
                model.anchor = id
            case "task":
                let id = url.lastPathComponent
                guard let task = model.snap.task(id) else { continue }
                model.place = task.isIdea ? .ideas : task.listId == ListModel.inbox ? .inbox : .list(task.listId)
                model.selection = [id]
                model.anchor = id
                showMain()
            case "show":
                if let place = Place(key: url.lastPathComponent) ?? model.snap.lists.first(where: { $0.handle == url.lastPathComponent }).map({ Place.list($0.id) }) {
                    model.place = place
                }
                showMain()
            case "search":
                model.place = .anytime
                model.filter = value("q") ?? ""
                showMain()
            case "settings":
                showSettings()
            case "quick":
                showQuickEntry()
            default:
                showMain()
            }
        }
    }

    // MARK: - menu actions

    @objc func showSettings() {
        if settings == nil {
            let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            made.contentViewController = NSHostingController(rootView: SettingsView(model: model, calendar: model.calendar))
            made.titlebarAppearsTransparent = true
            made.titleVisibility = .hidden
            made.title = "settings"
            made.backgroundColor = Theme.nsPaper
            made.isReleasedWhenClosed = false
            made.setContentSize(NSSize(width: 620, height: 760))
            made.center()
            settings = made
        }
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// ⌘⌥X brings it up, and again puts it away.
    @objc func showQuickEntry() {
        if quickPanel == nil { quickPanel = QuickEntryPanel(model: model) }
        guard let panel = quickPanel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.show() }
    }

    /// Quick entry, open (from Return or ⌘N where the window has no quick add): never closed by it.
    func openQuickEntry() {
        if quickPanel == nil { quickPanel = QuickEntryPanel(model: model) }
        quickPanel?.show()
    }

    @objc func about() {
        let credits = NSAttributedString(string: "things off your list.\nworks with oyl.",
                                         attributes: [.font: Theme.nsFont(13), .foregroundColor: Theme.nsSecondary])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "toyl", .applicationVersion: CLI.version, .credits: credits])
        NSApp.activate()
    }

    /// The caret in quick add; quick entry where there's no quick add (the page hidden, timers).
    @objc func newTask() {
        showMain()
        if model.place == .logbook { model.place = .inbox }
        model.editing = nil
        if !model.showTasks || model.place == .timers || !model.focusQuickAdd() { openQuickEntry() }
    }

    @objc func newList() { showMain(); model.newList() }
    @objc func newGroup() { showMain(); model.newGroup() }
    @objc func find() { showMain(); model.focusFilter += 1 }
    @objc func selectAll(_ sender: Any?) { model.selectAll() }
    @objc func checkOff() { model.toggleSelected() }
    @objc func dueToday() { model.setDue(Day.today()) }
    @objc func dueTomorrow() { model.setDue(Day.adding(1, to: Day.today())) }
    @objc func noDate() { model.setDue(nil) }
    @objc func pin() { model.togglePin() }
    @objc func someday() { model.toggleSomeday() }
    @objc func focusTimer() { model.startTimer() }
    @objc func stopwatch() { model.startTimer(stopwatch: true) }
    @objc func deleteTasks() { model.deleteSelected() }
    @objc func copyForAgent() { model.copyForAgent() }
    @objc func editTitle() { if let task = model.selectedTask { model.editing = task.id } }
    @objc func blockOnCalendar() { model.addToCalendar(model.selectedTask) }
    @objc func findTime() { if let task = model.selectedTask { model.calendar.schedule(task) } }
    @objc func breakDown() { if let task = model.selectedTask { model.breakDown(task) } }
    @objc func autosort() { model.place = .inbox; model.autosortEverything() }
    @objc func toggleDone() { model.showDone.toggle() }
    @objc func toggleSidebar() { model.showSidebar.toggle() }
    @objc func toggleDetails() { model.setShown(.details, !model.showInspector) }
    @objc func toggleCalendar() { model.setShown(.calendar, !model.showCalendar) }
    @objc func calendarBack() { model.stepDay(-1) }
    @objc func calendarOn() { model.stepDay(1) }
    @objc func calendarToday() { model.showDay(Day.today()) }
    @objc func calendarDayMode() { model.showCalendar = true; model.calendarMode = .day }
    @objc func calendarZoomIn() { model.zoomCalendar(1) }
    @objc func calendarZoomOut() { model.zoomCalendar(-1) }
    @objc func calendarZoomReset() { model.zoomCalendar(0) }
    @objc func togglePage() { model.setShown(.tasks, !model.showTasks) }
    @objc func calendarWeekMode() { model.showCalendar = true; model.calendarMode = .week }
    @objc func calendarMonthMode() { model.showCalendar = true; model.calendarMode = .month }

    /// Opening a panel the window hasn't room for widens the window (within the screen), so the
    /// list keeps its room.
    func makeRoom() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        var needed: CGFloat = model.showTasks ? 400 : 0
        if model.showSidebar { needed += model.sidebarWidth + 1 }
        if model.showInspector, model.place != .timers { needed += model.inspectorWidth + 1 }
        if model.showCalendar { needed += model.calendarWidth + 1 }
        var frame = window.frame
        guard frame.width < needed else { return }
        let room = screen.visibleFrame
        frame.size.width = min(needed, room.width)
        if frame.maxX > room.maxX { frame.origin.x = max(room.maxX - frame.width, room.minX) }
        window.setFrame(frame, display: true, animate: true)
    }
    @objc func openMarkdown() { NSWorkspace.shared.open(Paths.markdown) }
    @objc func openAgents() { AgentDocs.write(); NSWorkspace.shared.open(Paths.agents) }
    @objc func openFolder() { model.reveal(Paths.data) }

    /// ⌘1–6: the fixed places, in the sidebar's order.
    @objc func go(_ sender: NSMenuItem) {
        let places = model.placeOrder
        guard places.indices.contains(sender.tag) else { return }
        showMain()
        model.place = places[sender.tag]
    }

    /// While something's being typed, the task shortcuts give way to the text (⌘⌫ deletes to the
    /// line's start, not the task), and they need a task selected.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let typing = NSApp.keyWindow?.firstResponder is NSTextView
        let needsTasks: [Selector] = [#selector(checkOff), #selector(dueToday), #selector(dueTomorrow), #selector(noDate), #selector(pin),
                                      #selector(someday), #selector(focusTimer), #selector(stopwatch), #selector(deleteTasks),
                                      #selector(copyForAgent), #selector(editTitle), #selector(blockOnCalendar), #selector(findTime), #selector(breakDown)]
        guard let action = item.action else { return true }
        if action == #selector(go(_:)), model.placeOrder.indices.contains(item.tag) { item.title = model.title(model.placeOrder[item.tag]) }
        if needsTasks.contains(action) {
            if typing || model.selection.isEmpty { return false }
            if action == #selector(findTime) { return model.calendar.connected && model.selectedTask?.duration != nil }
            if action == #selector(blockOnCalendar) { return model.selectedTask != nil }
            if action == #selector(breakDown) { return OnDevice.isAvailable && model.selectedTask != nil }
        }
        if action == #selector(selectAll(_:)) { return !typing }
        if action == #selector(toggleDone) { item.state = model.showDone ? .on : .off }
        if action == #selector(toggleSidebar) { item.title = model.showSidebar ? "hide sidebar" : "show sidebar" }
        if action == #selector(toggleDetails) { item.state = model.showInspector ? .on : .off }
        if action == #selector(toggleCalendar) { item.state = model.showCalendar ? .on : .off }
        if [#selector(calendarBack), #selector(calendarOn), #selector(calendarToday)].contains(action) { return model.showCalendar && !typing }
        if action == #selector(calendarDayMode) { item.state = model.calendarMode == .day ? .on : .off }
        if action == #selector(togglePage) { item.state = model.showTasks ? .on : .off }
        if [#selector(calendarZoomIn), #selector(calendarZoomOut), #selector(calendarZoomReset)].contains(action) { return model.showCalendar && !typing }
        if action == #selector(calendarWeekMode) { item.state = model.calendarMode == .week ? .on : .off }
        if action == #selector(calendarMonthMode) { item.state = model.calendarMode == .month ? .on : .off }
        return true
    }
}

/// The menu bar, in lower case and toyl's face.
@MainActor
enum Menus {
    static func build(_ app: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let services = NSMenu(title: "services")
        NSApp.servicesMenu = services
        main.addItem(submenu("toyl", [
            item("about toyl", #selector(AppDelegate.about), target: app),
            .separator(),
            item("settings…", #selector(AppDelegate.showSettings), ",", target: app),
            .separator(),
            submenuItem("services", services),
            .separator(),
            item("hide toyl", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("hide others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("show all", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item("quit toyl", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ]))
        main.addItem(submenu("file", [
            item("new task", #selector(AppDelegate.newTask), "n", target: app),
            item("quick entry (⌘⌥x, from anywhere)", #selector(AppDelegate.showQuickEntry), target: app),
            item("new list", #selector(AppDelegate.newList), "n", [.command, .shift], target: app),
            item("new group", #selector(AppDelegate.newGroup), target: app),
            .separator(),
            item("open toyl.md", #selector(AppDelegate.openMarkdown), target: app),
            item("show the data folder", #selector(AppDelegate.openFolder), target: app),
            .separator(),
            item("close window", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu("edit", [
            item("undo", Selector(("undo:")), "z"),
            item("redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("cut", #selector(NSText.cut(_:)), "x"),
            item("copy", #selector(NSText.copy(_:)), "c"),
            item("paste", #selector(NSText.paste(_:)), "v"),
            item("select all", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            item("filter", #selector(AppDelegate.find), "f", target: app),
            item("emoji & symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control], target: NSApp),
        ]))
        main.addItem(submenu("task", [
            item("check off", #selector(AppDelegate.checkOff), "k", target: app),
            item("edit title", #selector(AppDelegate.editTitle), "e", target: app),
            .separator(),
            item("today", #selector(AppDelegate.dueToday), "t", target: app),
            item("tomorrow", #selector(AppDelegate.dueTomorrow), "t", [.command, .option], target: app),
            item("no date", #selector(AppDelegate.noDate), target: app),
            item("pin to the top", #selector(AppDelegate.pin), "p", [.command, .shift], target: app),
            item("to ideas (put off)", #selector(AppDelegate.someday), "s", [.command, .shift], target: app),
            .separator(),
            item("focus timer", #selector(AppDelegate.focusTimer), "t", [.command, .shift], target: app),
            item("stopwatch", #selector(AppDelegate.stopwatch), target: app),
            item("add to google calendar…", #selector(AppDelegate.blockOnCalendar), "g", [.command, .shift], target: app),
            item("find time for it", #selector(AppDelegate.findTime), target: app),
            item("break it into a sublist", #selector(AppDelegate.breakDown), target: app),
            .separator(),
            item("autosort the inbox", #selector(AppDelegate.autosort), "a", [.command, .option], target: app),
            item("copy for an agent", #selector(AppDelegate.copyForAgent), "c", [.command, .shift], target: app),
            .separator(),
            item("delete", #selector(AppDelegate.deleteTasks), "\u{8}", target: app),
        ]))
        let places = ["all", "inbox", "today", "in progress", "ideas", "timers"]
        main.addItem(submenu("view", places.enumerated().map { index, name in
            let made = item(name, #selector(AppDelegate.go(_:)), "\(index + 1)", target: app)
            made.tag = index
            return made
        } + [
            .separator(),
            item("show done", #selector(AppDelegate.toggleDone), "d", [.command, .shift], target: app),
            item("hide sidebar", #selector(AppDelegate.toggleSidebar), "s", [.command, .control], target: app),
            .separator(),
            item("page", #selector(AppDelegate.togglePage), target: app),
            item("description", #selector(AppDelegate.toggleDetails), "i", [.command, .option], target: app),
            item("calendar", #selector(AppDelegate.toggleCalendar), target: app),
            submenu("calendar", [
                item("earlier", #selector(AppDelegate.calendarBack), "[", [.command, .option], target: app),
                item("later", #selector(AppDelegate.calendarOn), "]", [.command, .option], target: app),
                item("today", #selector(AppDelegate.calendarToday), target: app),
                .separator(),
                item("day", #selector(AppDelegate.calendarDayMode), target: app),
                item("week", #selector(AppDelegate.calendarWeekMode), target: app),
                item("month", #selector(AppDelegate.calendarMonthMode), target: app),
                .separator(),
                item("zoom in", #selector(AppDelegate.calendarZoomIn), "=", target: app),
                item("zoom out", #selector(AppDelegate.calendarZoomOut), "-", target: app),
                item("usual size", #selector(AppDelegate.calendarZoomReset), target: app),
            ]),
            .separator(),
            item("enter full screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        let windows = submenu("window", [
            item("minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("zoom", #selector(NSWindow.performZoom(_:))),
            item("toyl", #selector(AppDelegate.showMain), "0", target: app),
            .separator(),
            item("bring all to front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp),
        ])
        main.addItem(windows)
        NSApp.windowsMenu = windows.submenu
        main.addItem(submenu("help", [
            item("how agents use toyl (AGENTS.md)", #selector(AppDelegate.openAgents), target: app),
            item("open toyl.md", #selector(AppDelegate.openMarkdown), target: app),
        ]))
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command],
                             target: AnyObject? = nil) -> NSMenuItem {
        let made = NSMenuItem(title: title, action: action, keyEquivalent: key)
        made.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        made.target = target
        made.attributedTitle = NSAttributedString(string: title, attributes: [.font: Theme.nsFont(14)])
        return made
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func submenuItem(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.attributedTitle = NSAttributedString(string: title, attributes: [.font: Theme.nsFont(14)])
        holder.submenu = menu
        return holder
    }
}
