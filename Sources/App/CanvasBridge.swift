import AppKit

/// Canvas, in the window: every half hour (and when asked), what's due comes in as tasks, moves
/// as Canvas moves it, and is checked off when it's submitted there.
@MainActor
final class CanvasBridge: ObservableObject {
    @Published private(set) var settings = CanvasSettings.load()
    @Published private(set) var busy = false
    @Published var said: String?
    @Published private(set) var connected = Canvas.isConnected

    private let store: Store
    private var every: Timer?

    init(store: Store) {
        self.store = store
        every = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pull() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.pull() }
    }

    private func change(_ edit: (inout CanvasSettings) -> Void) {
        var fresh = CanvasSettings.load()
        edit(&fresh)
        fresh.save()
        settings = fresh
    }

    func setOn(_ on: Bool) {
        change { $0.on = on }
        if on { pull() }
    }

    func setSite(_ text: String) {
        let site = Canvas.site(from: text)
        guard site.count > 10 else { return }
        change { $0.site = site }
    }

    /// A token or the calendar feed's address, pasted: which it is, it can tell.
    func connect(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 10 else { return false }
        if text.hasPrefix("http") || text.hasPrefix("webcal") { Canvas.setFeed(text) } else { Canvas.setToken(text) }
        connected = Canvas.isConnected
        change { $0.on = true }
        pull()
        return true
    }

    func forget() {
        Canvas.forget()
        connected = false
        change { $0.on = false }
    }

    var how: String { Canvas.token != nil ? "with a token" : Canvas.feed != nil ? "by its calendar feed" : "" }

    func pull() {
        settings = CanvasSettings.load()
        connected = Canvas.isConnected
        guard settings.on, connected, !busy else { return }
        busy = true
        let snapshot = settings
        Task { @MainActor in
            defer { busy = false }
            do {
                let items = try await Canvas.upcoming(snapshot)
                let outcome = Canvas.plan(items, snap: store.snap, settings: CanvasSettings.load())
                if !outcome.drafts.isEmpty || !outcome.patches.isEmpty || !outcome.finish.isEmpty {
                    let ids = outcome.drafts.map { _ in UID.make() }
                    store.change(outcome.said.isEmpty ? "canvas" : outcome.said, undoable: false) { Canvas.apply(outcome, ids: ids, to: &$0) }
                }
                Canvas.finish(outcome)
                settings = CanvasSettings.load()
                said = outcome.said.isEmpty ? nil : outcome.said
            } catch {
                said = "\(error)"
            }
        }
    }

    var lastPulled: String {
        guard let last = settings.lastPull else { return "never" }
        let minutes = Int(Date().timeIntervalSince(last) / 60)
        if minutes < 1 { return "just now" }
        return minutes < 60 ? "\(minutes)m ago" : minutes < 1440 ? "\(minutes / 60)h ago" : Format.day(Day.string(last))
    }
}
