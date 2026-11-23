import AppKit
import Combine

/// Pulling important email, in the window: every ten minutes (and when asked), from the inboxes
/// that are on, into the inbox list, each flagged as from email.
@MainActor
final class MailBridge: ObservableObject {
    enum OutlookState: Equatable { case setUp, signedOut, signingIn, connected }

    @Published private(set) var settings = MailSettings.load()
    @Published private(set) var busy = false
    @Published private(set) var outlook: OutlookState = .setUp
    /// What the last pull did, in a few words.
    @Published var said: String?

    private let store: Store
    private let calendar: CalendarBridge
    private var every: Timer?
    private var watching: AnyCancellable?

    var isOn: Bool { settings.gmail || settings.outlook }
    var gmailAllowed: Bool { GoogleAuth.allows(Gmail.scope) }

    init(store: Store, calendar: CalendarBridge) {
        self.store = store
        self.calendar = calendar
        updateOutlook()
        every = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.pull() }
        // Signed in to Google again (to allow Gmail, say): pull.
        watching = calendar.$state.removeDuplicates().dropFirst().filter { $0 == .connected }.sink { [weak self] _ in
            DispatchQueue.main.async { self?.pull() }
        }
    }

    private func updateOutlook() {
        if outlook == .signingIn { return }
        outlook = Outlook.client == nil ? .setUp : Outlook.isConnected ? .connected : .signedOut
    }

    private func change(_ edit: (inout MailSettings) -> Void) {
        var fresh = MailSettings.load()
        edit(&fresh)
        fresh.save()
        settings = fresh
    }

    // MARK: - settings

    /// Gmail on: Google's sign-in has to allow reading mail, so it's asked again if it doesn't.
    func setGmail(_ on: Bool) {
        change { $0.gmail = on; if on { $0.lastPull = nil } }
        if on, GoogleAuth.client != nil, !gmailAllowed { calendar.connect() }
        if on, gmailAllowed { pull() }
    }

    func setOutlook(_ on: Bool) {
        change { $0.outlook = on; if on { $0.lastPull = nil } }
        if on { outlook == .connected ? pull() : connectOutlook() }
    }

    func setAsk(_ on: Bool) { change { $0.ask = on } }

    func saveOutlookClient(_ text: String) -> Bool {
        guard let client = Outlook.client(from: text) else { return false }
        Outlook.setClient(client)
        updateOutlook()
        return true
    }

    func connectOutlook() {
        guard Outlook.client != nil else { said = "paste your outlook app's client id first"; return }
        outlook = .signingIn
        said = "finish signing in to microsoft in your browser"
        Task { @MainActor in
            do {
                try await Outlook.signIn { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
                outlook = .connected
                change { $0.outlook = true; $0.lastPull = nil }
                said = nil
                pull()
            } catch {
                outlook = Outlook.isConnected ? .connected : .signedOut
                said = "\(error)"
            }
        }
    }

    func disconnectOutlook() {
        Outlook.signOut()
        change { $0.outlook = false }
        updateOutlook()
    }

    // MARK: - pulling

    func pull() {
        settings = MailSettings.load()
        updateOutlook()
        guard isOn, !busy else { return }
        busy = true
        let snap = store.snap
        let useModel = settings.ask && OnDevice.isAvailable
        Task { @MainActor in
            let outcome = useModel ? await MailPull.fetch(snap: snap, ask: { message in await OnDevice.mailTask(message) })
                                   : await MailPull.fetch(snap: snap)
            let drafts = outcome.found.map(\.draft)
            if !drafts.isEmpty {
                let ids = drafts.map { _ in UID.make() }
                store.change(drafts.count == 1 ? "from email" : "\(drafts.count) from email", undoable: false) { doc in
                    for (draft, id) in zip(drafts, ids) { _ = doc.addTask(draft, id: id) }
                }
            }
            MailPull.finish(outcome)
            settings = MailSettings.load()
            busy = false
            if let error = outcome.errors.first {
                said = error
            } else {
                said = drafts.isEmpty ? nil : drafts.count == 1 ? "1 from email: " + drafts[0].title : "\(drafts.count) from email"
            }
        }
    }

    /// "5m ago", "never".
    var lastPulled: String {
        guard let last = settings.lastPull else { return "never" }
        let minutes = Int(Date().timeIntervalSince(last) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        return minutes < 1440 ? "\(minutes / 60)h ago" : Format.day(Day.string(last))
    }
}
