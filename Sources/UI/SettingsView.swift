import SwiftUI

/// Settings: an icon and a few words for each thing.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calendar: CalendarBridge
    @Local private var said: String?
    @Local private var refresh = 0
    @Local private var opensAtLogin = SMAppServiceBridge.isEnabled
    @Local private var clientText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("settings").font(Theme.title).padding(.top, 30)
                if let said {
                    Label(said, systemImage: "info.circle").font(Theme.small).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                calendarSection
                Hairline()
                agentsSection
                Hairline()
                autosortSection
                Hairline()
                generalSection
                Hairline()
                dataSection
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 36)
            .id(refresh)
        }
        .frame(minWidth: 480, minHeight: 520)
        .background(Theme.paper)
        .font(Theme.font(15))
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
    }

    // MARK: - pieces

    private func section(_ title: String, _ icon: String) -> some View {
        Label { Text(title).font(Theme.font(19, bold: true)) } icon: { Image(systemName: icon).foregroundStyle(Theme.accent) }
    }

    /// An icon, a few words (and fewer beneath, maybe), and what to do on the right.
    private func row<Trailing: View>(_ icon: String, _ words: String, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(words).font(Theme.font(15))
                if let hint { Text(hint).font(Theme.font(12.5)).foregroundStyle(Theme.faint) }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func switchRow(_ icon: String, _ words: String, hint: String? = nil, _ on: Binding<Bool>) -> some View {
        row(icon, words, hint: hint) { Toggle("", isOn: on).toggleStyle(.switch).controlSize(.small).labelsHidden() }
    }

    private func open(_ link: String) -> some View {
        Quiet(label: "open", symbol: "arrow.up.right") { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
    }

    // MARK: - google calendar

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("google calendar", "calendar")
            switch calendar.state {
            case .setUp:
                row("1.circle", "turn on the calendar api") { open("https://console.cloud.google.com/apis/library/calendar-json.googleapis.com") }
                row("2.circle", "audience: external, add you, publish") { open("https://console.cloud.google.com/auth/audience") }
                row("3.circle", "new desktop client, download its json") { open("https://console.cloud.google.com/auth/clients") }
                row("4.circle", "paste it here, then connect") { EmptyView() }
                clientField
            case .signedOut:
                row("link", "connect google calendar", hint: "signs in in your browser") {
                    Quiet(label: "connect", tint: Theme.ink) { calendar.connect() }
                }
                clientField
            case .signingIn:
                row("hourglass", "finish signing in, in your browser") { EmptyView() }
            case .connected:
                row("checkmark.circle", "connected") { Quiet(label: "disconnect") { calendar.disconnect() } }
                switchRow("eye", "events beside tasks", Binding(get: { calendar.showEvents }, set: { calendar.showEvents = $0 }))
                if !calendar.calendars.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calendar.calendars) { cal in
                            HStack(spacing: 8) {
                                CalendarMark(title: cal.title, color: cal.color).frame(width: 18)
                                Text(calendarName(cal)).font(Theme.font(15))
                                if !cal.labels.isEmpty {
                                    Image(systemName: "tag").font(.system(size: 9)).foregroundStyle(Theme.faint)
                                    Text("\(cal.labels.count)").font(Theme.font(12.5)).foregroundStyle(Theme.faint)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(get: { calendar.isShown(cal) }, set: { calendar.setShown(cal.id, $0) }))
                                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                            }
                            .help(cal.labels.map(\.name).filter { !$0.isEmpty }.joined(separator: ", "))
                        }
                    }
                    .padding(.leading, 28)
                }
                switchRow("tray.and.arrow.down", "“todo:” events → tasks", hint: "the event stays as it is",
                          Binding(get: { calendar.importTodos }, set: { calendar.importTodos = $0 }))
                row("doc.text", "your calendar rules") {
                    Quiet(label: "read") { CalendarGuide.write(); NSWorkspace.shared.open(CalendarGuide.file) }
                    Quiet(label: "file") { model.reveal(CalendarRules.file) }
                }
            }
        }
    }

    /// "✩ a academic" from the rules, else its name.
    private func calendarName(_ cal: CalInfo) -> String {
        guard let google = calendar.google.first(where: { $0.id == cal.id }), let sub = calendar.rules.sub(for: google) else { return cal.title.lowercased() }
        let rest = Mark(cal.title)?.rest ?? cal.title
        return sub.key == "♡" ? "primary" : (rest.isEmpty ? "" : rest.lowercased() + " ") + sub.about
    }

    private var clientField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $clientText)
                .font(Theme.font(13))
                .scrollContentBackground(.hidden)
                .frame(height: 50)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            HStack(spacing: 16) {
                Quiet(label: "save", symbol: "key", tint: Theme.ink) {
                    if calendar.saveClient(clientText) {
                        clientText = ""
                        said = "saved in your keychain. now connect."
                    } else {
                        said = "that isn't a google client. paste its json."
                    }
                }
                if GoogleAuth.client != nil, calendar.state != .connected {
                    Quiet(label: "connect", symbol: "link", tint: Theme.ink) { calendar.connect() }
                }
            }
        }
        .padding(.leading, 28)
    }

    // MARK: - agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("agents", "sparkles")
            connection("bubble.left.and.text.bubble.right", "claude desktop", hint: "reopen claude after", Integrations.claudeDesktopConnected) {
                try Integrations.connectClaudeDesktop()
                return "linked. reopen claude."
            }
            connection("terminal", "claude code", Integrations.claudeCodeConnected) {
                try Integrations.connectClaudeCode()
                return "linked to claude code."
            }
            connection("m.circle", "muse code", Integrations.museCodeConnected) {
                try Integrations.connectMuseCode()
                return "linked to muse code."
            }
            connection("chevron.left.forwardslash.chevron.right", "toyl command", hint: "toyl --help", Integrations.commandInstalled) {
                try Integrations.installCommand()
                return "toyl is ready in new terminals."
            }
            row("calendar.badge.plus", "instinct and muse", hint: "through google calendar") { EmptyView() }
            row("doc.text", "files for agents") {
                Quiet(label: "toyl.md") { NSWorkspace.shared.open(Paths.markdown) }
                Quiet(label: "agents.md") { AgentDocs.write(); NSWorkspace.shared.open(Paths.agents) }
                Quiet(label: "folder") { model.reveal(Paths.data) }
            }
        }
    }

    private func connection(_ icon: String, _ name: String, hint: String? = nil, _ linked: Bool, _ link: @escaping () throws -> String) -> some View {
        row(icon, name, hint: hint) {
            if linked {
                Label("linked", systemImage: "checkmark").font(Theme.small).foregroundStyle(Theme.accent)
            } else {
                Quiet(label: "link", tint: Theme.ink) {
                    do { said = try link() } catch { said = "\(error)" }
                    refresh += 1
                }
            }
        }
    }

    // MARK: - autosort

    private var autosortSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("autosort", "wand.and.stars")
            switchRow("arrow.triangle.branch", "file new tasks for me", hint: "only when it's sure", $model.suggestWhileTyping)
            row("apple.intelligence", OnDevice.isAvailable ? "apple intelligence on" : "apple intelligence off",
                hint: OnDevice.isAvailable ? "asks it when unsure · breaks tasks into steps" : "turn it on to break tasks into steps") { EmptyView() }
        }
    }

    // MARK: - general

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("general", "gearshape")
            switchRow("power", "open at login", Binding(get: { opensAtLogin }, set: { SMAppServiceBridge.set($0); opensAtLogin = SMAppServiceBridge.isEnabled }))
            switchRow("textformat.abc", "my typing in lowercase too", $model.lowercaseAll)
            row("timer", "focus timer") {
                Picker("", selection: Binding(get: { Int(model.timers.defaultMinutes) }, set: { UserDefaults.standard.set(Double($0), forKey: TimerEngine.defaultMinutesKey); refresh += 1 })) {
                    ForEach([15, 20, 25, 30, 45, 50, 60, 90], id: \.self) { Text(Format.minutes($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            row("calendar", "weeks start") {
                Picker("", selection: Binding(get: { model.snap.weekStart }, set: { start in
                    model.store.change("week start") { doc in
                        var settings = doc.json["settings"] as? [String: Any] ?? [:]
                        settings["weekStart"] = start
                        doc.json["settings"] = settings
                    }
                })) {
                    Text("monday").tag(1)
                    Text("sunday").tag(0)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            row("keyboard", "⌃⌥T add from anywhere", hint: "⌘1–5 places · ⌘K check off · ⇧⌘T timer") { EmptyView() }
        }
    }

    // MARK: - data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("your data", "externaldrive")
            row("lock", "all on this mac", hint: "backups every 10 min · a copy a day") {
                Quiet(label: "folder", symbol: "folder") { model.reveal(Paths.data) }
            }
        }
    }
}

import ServiceManagement

/// The panel ⌃⌥T brings up over any app: type a task, Return, and it's in (and you're back
/// where you were).
final class QuickEntryPanel: NSPanel {
    init(model: AppModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 118),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = Theme.nsPaper
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        contentView = NSHostingView(rootView: QuickEntryView(model: model) { [weak self] in self?.orderOut(nil) })
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    /// Clicking anywhere else puts it away, as Spotlight goes.
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.maxY - frame.height * 0.28))
        }
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .toylQuickEntry, object: nil)
    }
}

extension Notification.Name {
    static let toylQuickEntry = Notification.Name("toyl.quickEntry")
}

struct QuickEntryView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @Local private var text = ""
    @Local private var focus = 1
    @Local private var added: String?

    var body: some View {
        let parsed = text.isEmpty ? nil : Quick.parse(text, lists: model.snap.lists, weekStart: model.snap.weekStart)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(added.map { "added “\($0)”" } ?? "add to toyl", systemImage: added == nil ? "plus" : "checkmark")
                    .font(Theme.font(13.5)).foregroundStyle(added == nil ? Theme.faint : Theme.accent)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: added)
                Spacer()
                HStack(spacing: 12) {
                    Label("add", systemImage: "return")
                    Label("another", systemImage: "command")
                    Label("close", systemImage: "escape")
                }
                .font(Theme.font(12.5))
                .foregroundStyle(Theme.faint)
                Quiet(label: "", symbol: "xmark", size: 12, action: close).help("close (esc)")
            }
            PlainField(text: $text, placeholder: "essay draft fri 5pm #cs ~2h", font: Theme.nsFont(22), focus: focus,
                       onSubmit: { add(keepOpen: NSEvent.modifierFlags.contains(.command)) }, onEscape: close)
                .frame(height: 28)
            HStack(spacing: 6) {
                if let parsed {
                    ForEach(parsed.tokens(lists: model.snap.lists), id: \.self) { Chip(text: $0.text, filled: true) }
                    if parsed.listId == nil, parsed.newList == nil, !parsed.idea, let guess = model.suggestion(for: parsed.title) {
                        Chip(text: "→ " + model.display(guess.list.displayName))
                    }
                } else {
                    Text("?  idea    #  list or tag    by fri  aim    ~30m  length    /timer    !  pin").font(Theme.font(12.5)).foregroundStyle(Theme.faint)
                }
                Spacer()
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .toylQuickEntry)) { _ in
            added = nil
            focus += 1
        }
    }

    private func add(keepOpen: Bool) {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return close() }
        var draft = Quick.parse(typed, lists: model.snap.lists, weekStart: model.snap.weekStart).draft(source: "quick entry")
        if draft.listId == nil, draft.newListName == nil, model.suggestWhileTyping, let guess = model.suggestion(for: draft.title) { draft.listId = guess.list.id }
        model.store.add(draft)
        text = ""
        if keepOpen { added = draft.title } else { close() }
    }
}
