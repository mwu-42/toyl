import AppKit
import UserNotifications

/// Timers, for the window: each counts down (or up) from what's in toyl.json, so one started
/// from the command line, an agent or Oyl's notch shows here too. When a countdown's done, its
/// time goes on its task and it rings: a chime, a notification (with "5 more minutes" and
/// "check it off"), and Oyl's notch if Oyl's showing it (then Oyl does the ringing).
@MainActor
final class TimerEngine: ObservableObject {
    /// Ticks each second while any timer's going, for what's shown.
    @Published private(set) var now = Date()
    /// A countdown that's just finished, till it's seen to.
    @Published private(set) var ringing: TimerModel?

    static let defaultMinutesKey = "timers.minutes"
    /// The lengths offered for a timer, one tap each: 10m, 30m, 1h, 6h, 24h.
    static let presets = [10, 30, 60, 360, 1440]
    var defaultMinutes: Double {
        let saved = UserDefaults.standard.double(forKey: Self.defaultMinutesKey)
        return saved > 0 ? saved : 30
    }

    private let store: Store
    private var ticker: Timer?
    private lazy var alarm = WallClockAlarm { [weak self] in self?.reschedule() }
    private var finishing: Set<String> = []
    private var chiming: Timer?
    private var chimes = 0
    private let notifier = Notifier()

    init(store: Store) {
        self.store = store
        store.onChange.append { [weak self] _ in self?.reschedule() }
        notifier.onAction = { [weak self] action, label, task in
            MainActor.assumeIsolated { self?.answer(action, label: label, task: task) }
        }
        reschedule()
    }

    var timers: [TimerModel] { store.snap.timers }

    func timer(for task: String) -> TimerModel? { timers.first { $0.taskId == task } }

    /// Starts a countdown (the task's own length, else the usual 25 minutes) or a stopwatch. A
    /// task already being timed is paused or carried on instead.
    func start(task: TaskModel?, minutes: Double? = nil, stopwatch: Bool = false, label: String? = nil) {
        if let task, let going = timer(for: task.id) { return togglePause(going.id) }
        let length = (minutes ?? task?.duration.map(Double.init) ?? defaultMinutes) * 60
        // A countdown asks to be held on Oyl's closed notch, where it's seen from any app.
        let timer = TimerModel(label: label ?? task?.title ?? "timer", taskId: task?.id, kind: stopwatch ? .stopwatch : .countdown,
                               duration: stopwatch ? 0 : min(max(length, 1), 7 * 86400), pin: !stopwatch)
        store.change("start timer", undoable: false) { $0.putTimer(timer) }
        notifier.ask()
    }

    func togglePause(_ id: String) {
        guard var timer = timers.first(where: { $0.id == id }) else { return }
        let now = Date()
        switch timer.kind {
        case .countdown:
            if let end = timer.endsAt {
                timer.pausedLeft = max(end.timeIntervalSince(now), 0)
                timer.endsAt = nil
            } else {
                timer.endsAt = now.addingTimeInterval(timer.pausedLeft ?? timer.duration)
                timer.pausedLeft = nil
            }
        case .stopwatch:
            if let since = timer.runningSince {
                timer.elapsed += max(now.timeIntervalSince(since), 0)
                timer.runningSince = nil
            } else {
                timer.runningSince = now
            }
        }
        let changed = timer
        store.change("pause timer", undoable: false) { $0.putTimer(changed) }
    }

    /// Stops a timer; the time it ran goes on its task.
    func stop(_ id: String) {
        let now = Date()
        store.change("stop timer", undoable: false) { $0.finishTimer(id, at: now) }
    }

    /// More time on a countdown (what it was set for grows by as much, so its ring fills back up).
    func extend(_ id: String, minutes: Double) {
        guard var timer = timers.first(where: { $0.id == id }), timer.kind == .countdown else { return }
        let added = minutes * 60
        timer.duration += added
        if let end = timer.endsAt { timer.endsAt = end.addingTimeInterval(added) } else { timer.pausedLeft = (timer.pausedLeft ?? 0) + added }
        let changed = timer
        store.change("more time", undoable: false) { $0.putTimer(changed) }
    }

    func dismissRinging() {
        ringing = nil
        stopChime()
    }

    /// Five (or so) more minutes on the timer that just rang.
    func snooze(minutes: Double = 5) {
        guard let rang = ringing else { return }
        dismissRinging()
        start(task: rang.taskId.flatMap { store.snap.task($0) }, minutes: minutes, label: rang.label)
    }

    /// Rings any that have finished, sets the alarm for the next, and ticks while any's going.
    private func reschedule() {
        let now = Date()
        self.now = now
        let finished = timers.filter { $0.isFinished(at: now) && !finishing.contains($0.id) }
        if !finished.isEmpty {
            finishing.formUnion(finished.map(\.id))
            store.change("timer done", undoable: false) { doc in
                for timer in finished { doc.finishTimer(timer.id, at: now, seconds: timer.duration) }
            }
            for timer in finished { ring(timer) }
        }
        finishing.formIntersection(Set(timers.map(\.id)))
        alarm.set(timers.filter { !$0.isFinished(at: now) }.compactMap(\.endsAt).min())
        let going = timers.contains(where: \.isRunning)
        if going, ticker == nil {
            let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            ticker.tolerance = 0.1
            RunLoop.main.add(ticker, forMode: .common)
            self.ticker = ticker
        } else if !going {
            ticker?.invalidate()
            ticker = nil
        }
        badge()
    }

    private func tick() {
        now = Date()
        badge()
    }

    /// The soonest countdown's minutes left on the Dock icon.
    private func badge() {
        let soonest = timers.filter { $0.kind == .countdown && $0.isRunning }.map { $0.remaining(at: now) }.min()
        let label = soonest.map { $0 >= 60 ? "\(Int(($0 / 60).rounded(.up)))m" : "\(Int($0.rounded(.up)))s" }
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    private func ring(_ timer: TimerModel) {
        ringing = timer
        // Oyl's notch has it, and rings it there.
        let oylRings = timer.mirroredByOyl && !NSRunningApplication.runningApplications(withBundleIdentifier: "local.nott").isEmpty
        guard !oylRings else { return }
        notifier.post(timer)
        stopChime()
        chimes = 0
        playChime()
        chiming = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playChime() }
        }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func playChime() {
        chimes += 1
        NSSound(named: NSSound.Name("Glass"))?.play()
        if chimes >= 3 { stopChime() }
    }

    private func stopChime() {
        chiming?.invalidate()
        chiming = nil
    }

    /// A notification's button.
    private func answer(_ action: String, label: String?, task: String?) {
        switch action {
        case "more5":
            start(task: task.flatMap { store.snap.task($0) }, minutes: 5, label: label)
            dismissRinging()
        case "done":
            if let task, store.snap.task(task)?.done == false { store.toggle([task]) }
            dismissRinging()
        default:
            NSApp.activate()
        }
    }
}

/// Posts a timer's notification, and hears which of its buttons was clicked.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onAction: ((String, String?, String?) -> Void)?
    private var asked = false

    override init() {
        super.init()
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let more = UNNotificationAction(identifier: "more5", title: "5 more minutes")
        let done = UNNotificationAction(identifier: "done", title: "check it off")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "toyl.task", actions: [done, more], intentIdentifiers: []),
            UNNotificationCategory(identifier: "toyl.timer", actions: [more], intentIdentifiers: []),
        ])
    }

    /// Asks once, the first time a timer's started (not before: no asking for what's not used).
    func ask() {
        guard !asked, Bundle.main.bundleIdentifier != nil else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ timer: TimerModel) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = timer.label.isEmpty ? "timer" : timer.label
        content.body = timer.taskId != nil ? "time's up. done, or five more minutes?" : "time's up"
        content.sound = .default
        content.categoryIdentifier = timer.taskId != nil ? "toyl.task" : "toyl.timer"
        content.userInfo = ["task": timer.taskId ?? "", "label": timer.label]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: timer.id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let task = (info["task"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let label = info["label"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async { self.onAction?(action, label, task) }
        completionHandler()
    }
}

// Copied from Oyl (Sources/Timers.swift): timers go off by the wall clock, so one that spans a
// night asleep still rings on time.
/// Goes off at a time on the clock on the wall.
///
/// A `Timer` (like `DispatchTime`) counts only the time the Mac's been awake, so one set for 14
/// hours goes off late by however long the Mac slept in between. That includes the seconds at a
/// time it naps overnight, hundreds of times a night with the lid shut or the screen off, which
/// add up to minutes. This alarm is set by the wall clock instead (a strict dispatch timer on wall
/// time), and checked again the moment the Mac wakes or its clock is changed, and every half
/// minute besides. So it goes off on time while the Mac's awake, and as soon as it wakes if it was
/// asleep then.
@MainActor
final class WallClockAlarm {
    /// When it's set to go off, if it is.
    private(set) var date: Date?
    private let action: @MainActor () -> Void
    nonisolated(unsafe) private var source: DispatchSourceTimer?
    nonisolated(unsafe) private var backstop: Timer?
    nonisolated(unsafe) private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
        let workspace = NSWorkspace.shared.notificationCenter
        let woken = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification]
        let watched = woken.map { (workspace, $0) } + [(NotificationCenter.default, .NSSystemClockDidChange)]
        observers = watched.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(rearming: true) }
            })
        }
    }

    deinit {
        source?.cancel()
        backstop?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
    }

    /// Sets it to go off at `date` (at once, if that's gone by), in place of whenever it was set
    /// for; or, with nil, not at all.
    func set(_ date: Date?) {
        self.date = date
        arm()
    }

    private func arm() {
        source?.cancel()
        source = nil
        guard let date else {
            backstop?.invalidate()
            backstop = nil
            return
        }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(wallDeadline: .now() + max(date.timeIntervalSinceNow, 0), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check(rearming: true) }
        }
        timer.resume()
        source = timer
        if backstop == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(rearming: false) }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            backstop = timer
        }
    }

    /// Goes off if its time has come. If not and `rearming`, it's set again by the clock as it is
    /// now (for a wake, a changed clock, or a dispatch timer that fired a moment early).
    private func check(rearming: Bool) {
        guard let date else { return }
        if date <= Date() {
            set(nil)
            action()
        } else if rearming {
            arm()
        }
    }
}

// Copied from Oyl (Sources/Timers.swift): reads a timer typed as you'd say it ("10m stretch",
// "tea 4 min", "25m essay /pin").
/// Reads a duration out of free text, so "10m stretch" or "tea 4 min" both work.
enum ReminderParser {
    /// The longest a timer can run.
    static let longest: TimeInterval = 7 * 24 * 3600

    private static let unitPattern = try! NSRegularExpression(
        pattern: #"(\d+(?:[.,]\d+)?)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#,
        options: [.caseInsensitive])
    private static let numberPattern = try! NSRegularExpression(pattern: #"\b(\d+(?:[.,]\d+)?)\b"#)
    private static let pinPattern = try! NSRegularExpression(pattern: #"(?<!\S)/pin(?!\S)"#, options: [.caseInsensitive])
    private static let endlessPattern = try! NSRegularExpression(pattern: #"(?:\binf(?:inite)?\b|∞)"#, options: [.caseInsensitive])

    /// The time, the name, and whether "/pin" (anywhere in it) asks for it to be held on the notch.
    static func parse(_ text: String) -> (duration: TimeInterval?, label: String, pin: Bool) {
        let (text, pin) = unpinned(text)
        var label = text
        var total: TimeInterval = 0
        let source = text as NSString
        // Reversed so earlier ranges stay valid while later matches are cut out.
        for match in unitPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let unit = source.substring(with: match.range(at: 2)).lowercased()
            total += number(source.substring(with: match.range(at: 1)))
                * (unit.hasPrefix("d") ? 24 * 3600 : unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1)
            label = (label as NSString).replacingCharacters(in: match.range, with: " ")
        }
        // A bare number means minutes.
        if total == 0, let match = numberPattern.firstMatch(in: label, range: NSRange(location: 0, length: (label as NSString).length)) {
            total = number((label as NSString).substring(with: match.range(at: 1))) * 60
            label = (label as NSString).replacingCharacters(in: match.range, with: " ")
        }
        var words = label.split(whereSeparator: \.isWhitespace).map(String.init)
        // "call mom in 90s": drop the connector the duration leaves behind.
        if total > 0 {
            let connectors: Set = ["in", "for", "after"]
            while let last = words.last, connectors.contains(last.lowercased()) { words.removeLast() }
            while let first = words.first, connectors.contains(first.lowercased()) { words.removeFirst() }
        }
        return (total > 0 ? min(total, longest) : nil, words.joined(separator: " "), pin)
    }

    /// `text` without any "/pin" in it, and whether there was one.
    static func unpinned(_ text: String) -> (text: String, pin: Bool) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        guard pinPattern.firstMatch(in: text, range: whole) != nil else { return (text, false) }
        let rest = pinPattern.stringByReplacingMatches(in: text, range: whole, withTemplate: " ")
        return (rest.split(whereSeparator: \.isWhitespace).joined(separator: " "), true)
    }

    /// "inf" (or "∞") instead of a time: for as long as it takes (staying awake till it's stopped).
    static func isEndless(_ text: String) -> Bool {
        endlessPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// A time as it'd be typed: "12m 34s", or past an hour "1h 5m" (rounded up, as the countdown
    /// shows it), and how long that reads back as.
    static func spell(_ seconds: TimeInterval) -> (text: String, duration: TimeInterval) {
        var total = max(Int((seconds - 0.001).rounded(.up)), 1)
        if total >= 3600 { total = (total + 59) / 60 * 60 }
        let parts = [(total / 86400, "d"), (total % 86400 / 3600, "h"), (total % 3600 / 60, "m"), (total % 60, "s")]
        return (parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined(separator: " "), TimeInterval(total))
    }

    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
