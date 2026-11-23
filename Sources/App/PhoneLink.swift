import AppKit
import CoreImage
import CryptoKit
import SwiftUI

/// toyl on your iPhone: a page the Mac serves to your phone (on the same Wi-Fi, or from anywhere
/// with Tailscale on both), saved to the home screen as an app. It's made for adding tasks and
/// running timers: a big field to add to, your lists to file into, timers to start, pause and
/// stop, and today's tasks to check off or time.
///
/// Off till it's turned on (settings › iphone), and then only for a phone that's been paired: by
/// scanning the code settings shows (or typing its six digits), which leaves a long key on the
/// phone, as a cookie, that every request after has to carry. toyl keeps only the key's hash.
/// The server (`PhoneServer`, Oyl's) answers devices beside the Mac alone, each request only when
/// it's sent to the Mac by name, and one that changes anything only from toyl's own page.
@MainActor
final class PhoneLink: ObservableObject {
    struct Pairing: Equatable {
        var code: String
        var until: Date
        var tries = 0
        var paired: String?
        var isSpent: Bool { tries >= 5 }
    }

    struct Device: Codable, Equatable, Identifiable {
        var hash: String
        var name: String
        var paired: Date
        var seen: Date
        var id: String { hash }
    }

    @Published private(set) var isOn: Bool
    @Published private(set) var pairing: Pairing?
    @Published private(set) var pairingPicture: CGImage?
    @Published private(set) var devices: [Device]
    @Published private(set) var status: PhoneServer.Status?
    @Published private(set) var tailnetName: String?
    private(set) var port: UInt16

    static let defaultPort: UInt16 = 47650
    static let cookie = "toyl"

    private unowned let model: AppModel
    private let defaults = UserDefaults.standard
    private var server: PhoneServer?
    private var saved = Date.distantPast
    private var lastSeen: [String: Date] = [:]
    private var endPairing: DispatchWorkItem?
    private var tailnetCheck: Timer?
    /// The task last deleted from the phone, to put back if asked.
    private var deleted: [String: Any]?
    /// A fixed code and port, for trying it out (`toyl __phone`).
    private let testing: (code: String, port: UInt16)?

    init(model: AppModel, testing: (code: String, port: UInt16)? = nil) {
        self.model = model
        self.testing = testing
        isOn = testing != nil || defaults.bool(forKey: "phone.on")
        port = testing?.port ?? (defaults.object(forKey: "phone.port") as? Int).map { UInt16(clamping: $0) } ?? Self.defaultPort
        devices = testing != nil ? [] : defaults.data(forKey: "phone.devices").flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? []
        if isOn { start() }
        if let testing { pairing = Pairing(code: testing.code, until: Date().addingTimeInterval(3600)) }
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on { start() } else { stop(); stopPairing() }
        save()
    }

    /// A code to pair a phone with, for five minutes (and the link on, if it wasn't).
    func pair() {
        setOn(true)
        endPairing?.cancel()
        pairing = Pairing(code: String(format: "%06d", Int.random(in: 0..<1_000_000)), until: Date().addingTimeInterval(300))
        pairingPicture = pairingAddress.flatMap(Self.qrCode)
        lookForTailnet()
        let end = DispatchWorkItem { [weak self] in
            guard let self, self.pairing?.paired == nil else { return }
            self.stopPairing()
        }
        endPairing = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: end)
    }

    func stopPairing() {
        endPairing?.cancel()
        pairing = nil
        pairingPicture = nil
    }

    func forget() {
        devices = []
        save()
    }

    var overTailscale: Bool { !PhoneNetwork.tailnetAddresses().isEmpty }

    /// Where the phone opens toyl: the Mac's tailnet name with Tailscale running (works from
    /// anywhere), else its name on the Wi-Fi.
    var address: String {
        let tailnet = PhoneNetwork.tailnetAddresses()
        var host = tailnet.isEmpty ? PhoneNetwork.localName ?? PhoneNetwork.addresses().first { !$0.ipv6 }?.text ?? "localhost"
            : tailnetName ?? (tailnet.first { !$0.ipv6 } ?? tailnet[0]).text
        if host.contains(":") { host = "[\(host)]" }
        return "http://\(host.lowercased()):\(port)"
    }

    var pairingAddress: String? { pairing.map { "\(address)/pair?code=\($0.code)" } }

    private func lookForTailnet() {
        guard testing == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let name = PhoneNetwork.askTailscale()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard name != self.tailnetName else { return }
                    self.tailnetName = name
                    if self.pairing?.paired == nil, self.pairing != nil { self.pairingPicture = self.pairingAddress.flatMap(Self.qrCode) }
                }
            }
        }
    }

    private func start() {
        guard server == nil else { return }
        lookForTailnet()
        let check = Timer(timeInterval: 300, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.lookForTailnet() } }
        RunLoop.main.add(check, forMode: .common)
        tailnetCheck = check
        status = .starting
        let server = PhoneServer(respond: { [weak self] request in
            self?.respond(to: request) ?? .text(404, "Not here")
        }, status: { [weak self] status in
            guard let self else { return }
            self.status = status
            if case let .listening(port) = status, port != self.port {
                self.port = port
                self.save()
            }
        })
        self.server = server
        server.start(port: port)
    }

    private func stop() {
        server?.stop()
        server = nil
        status = nil
        tailnetCheck?.invalidate()
        tailnetCheck = nil
    }

    private func save() {
        for index in devices.indices {
            if let seen = lastSeen[devices[index].hash] { devices[index].seen = seen }
        }
        lastSeen = [:]
        saved = Date()
        guard testing == nil else { return }
        defaults.set(isOn, forKey: "phone.on")
        defaults.set(Int(port), forKey: "phone.port")
        defaults.set(try? JSONEncoder().encode(devices), forKey: "phone.devices")
    }

    // MARK: - answering

    func respond(to request: PhoneRequest, at now: Date = Date()) -> PhoneResponse {
        let hosts = PhoneNetwork.hostNames(tailnetName: tailnetName)
        guard let host = request.host, hosts.contains(host) else { return .text(421, "Not here") }
        switch (request.method, request.path) {
        case ("GET", "/"):
            return PhoneResponse(status: 200, type: "text/html; charset=utf-8", body: Data(PhonePage.html.utf8))
        case ("GET", "/app.js"):
            return PhoneResponse(status: 200, type: "text/javascript; charset=utf-8", body: Data(PhonePage.script.utf8))
        case ("GET", "/manifest.json"):
            return PhoneResponse(status: 200, type: "application/manifest+json", body: Data(PhonePage.manifest.utf8))
        case ("GET", "/icon.png"):
            return PhoneResponse(status: 200, type: "image/png", body: PhonePage.icon)
        case ("GET", "/pair"):
            guard let key = pair(code: request.query["code"], from: request.headers["user-agent"], at: now) else { return .redirect("/?unpaired=1") }
            return .redirect("/", headers: ["Set-Cookie": Self.setCookie(key)])
        case ("POST", "/api/pair"):
            guard isOwnPage(request, hosts: hosts) else { return .text(403, "Not from toyl") }
            let code = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["code"] as? String
            guard let key = pair(code: code, from: request.headers["user-agent"], at: now) else {
                return .json(["error": pairing == nil ? "ask the mac for a code: settings › iphone › pair" : "that's not the code"], status: 403)
            }
            var response = PhoneResponse.json(["paired": true])
            response.headers["Set-Cookie"] = Self.setCookie(key)
            return response
        case ("GET", "/api/state"):
            guard known(request, at: now) else { return .json(["error": "unpaired"], status: 401) }
            return .json(state(at: now))
        case ("GET", "/api/parse"):
            guard known(request, at: now) else { return .json(["error": "unpaired"], status: 401) }
            return .json(parse(request.query["text"] ?? ""))
        case ("POST", "/api/do"):
            guard isOwnPage(request, hosts: hosts) else { return .text(403, "Not from toyl") }
            guard known(request, at: now) else { return .json(["error": "unpaired"], status: 401) }
            guard let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any], let verb = fields["do"] as? String else {
                return .json(["error": "not something toyl does"], status: 400)
            }
            return perform(verb, fields, at: now)
        case (_, "/"), (_, "/app.js"), (_, "/pair"), (_, "/api/pair"), (_, "/api/state"), (_, "/api/parse"), (_, "/api/do"):
            return .text(405, "Not that way")
        default:
            return .text(404, "Not here")
        }
    }

    private func isOwnPage(_ request: PhoneRequest, hosts: Set<String>) -> Bool {
        guard request.headers["x-toyl"] == "1", request.headers["content-type"]?.hasPrefix("application/json") == true else { return false }
        guard let origin = request.headers["origin"] else { return true }
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return hosts.contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    private func known(_ request: PhoneRequest, at now: Date) -> Bool {
        guard let key = request.cookie(Self.cookie) else { return false }
        let hash = Self.hash(key)
        guard devices.contains(where: { $0.hash == hash }) else { return false }
        lastSeen[hash] = now
        if now.timeIntervalSince(saved) > 60 { save() }
        return true
    }

    private func pair(code: String?, from agent: String?, at now: Date) -> String? {
        guard var pairing, pairing.paired == nil, !pairing.isSpent, now < pairing.until, let code else { return nil }
        let tried = Array(code.filter(\.isNumber).utf8), wanted = Array(pairing.code.utf8)
        guard tried.count == wanted.count, zip(tried, wanted).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            pairing.tries += 1
            self.pairing = pairing
            return nil
        }
        let key = Self.newKey()
        let name = agent?.contains("iPhone") == true ? "iphone" : agent?.contains("iPad") == true ? "ipad" : "phone"
        devices.append(Device(hash: Self.hash(key), name: name, paired: now, seen: now))
        save()
        pairing.paired = name
        self.pairing = pairing
        if testing == nil {
            let end = DispatchWorkItem { [weak self] in self?.stopPairing() }
            endPairing = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: end)
        } else {
            self.pairing?.paired = nil
        }
        return key
    }

    // MARK: - what the phone sees and does

    struct State: Encodable {
        struct Task: Encodable {
            var id: String
            var title: String
            var when: String?
            var late: Bool
            var list: String?
            var mark: String?
            var color: String?
            var timer: Bool
            var email: Bool
            var sublist: Int
            var progress: Bool
            var project: String?
        }
        /// A list and its open tasks.
        struct Group: Encodable {
            var id: String
            var name: String
            var mark: String?
            var color: String
            var tasks: [Task]
        }
        struct List: Encodable {
            var id: String
            var name: String
            var mark: String?
            var color: String
        }
        struct Timer: Encodable {
            var id: String
            var title: String
            var task: String?
            var stopwatch: Bool
            /// A running countdown's end, or how long a paused one has left.
            var ends: Double?
            var left: Double?
            var duration: Double
            /// A running stopwatch's start, and what it had before.
            var since: Double?
            var elapsed: Double
        }
        var mac: String
        var now: Double
        var groups: [Group]
        var inbox: Int
        var lists: [List]
        var timers: [Timer]
        var presets: [Int]
        var standard: Int
        var ringing: String?
    }

    func state(at now: Date = Date()) -> State {
        let snap = model.snap
        let open = Views.tasks(for: .anytime, in: snap, now: now)
        let groups = Views.groups(open, place: .anytime, mode: .list, sort: model.sortMode(.anytime), snap: snap, now: now)
        let timers = model.timers.timers
        let running = Set(timers.compactMap(\.taskId))
        return State(
            mac: PhoneNetwork.computerName,
            now: now.timeIntervalSince1970,
            groups: groups.compactMap { group -> State.Group? in
                guard let id = group.listId, let list = snap.list(id), !list.isDump else { return nil }
                return State.Group(id: id, name: list.isSpecial ? list.displayName : list.bareName, mark: list.isSpecial ? nil : list.mark?.text,
                                   color: list.color, tasks: group.tasks.filter { !$0.done }.map { phoneTask($0, snap: snap, now: now, running: running) })
            },
            inbox: snap.tasks.filter { !$0.done && $0.listId == ListModel.inbox }.count,
            lists: snap.sidebarOrder.filter { !$0.archived && !$0.isDump }.map { list in
                State.List(id: list.id, name: list.isSpecial ? list.displayName : list.bareName, mark: list.isSpecial ? nil : list.mark?.text, color: list.color)
            },
            timers: timers.map { timer in
                State.Timer(id: timer.id, title: timer.label, task: timer.taskId, stopwatch: timer.kind == .stopwatch,
                            ends: timer.endsAt?.timeIntervalSince1970, left: timer.kind == .countdown && timer.endsAt == nil ? timer.remaining(at: now) : nil,
                            duration: timer.duration, since: timer.runningSince?.timeIntervalSince1970, elapsed: timer.elapsed)
            },
            presets: TimerEngine.presets,
            standard: Int(model.timers.defaultMinutes),
            ringing: model.timers.ringing?.label)
    }

    private func phoneTask(_ task: TaskModel, snap: Snapshot, now: Date, running: Set<String>) -> State.Task {
        let list = snap.list(task.listId)
        return State.Task(id: task.id, title: task.title, when: Format.due(task, now: now), late: task.isLate(at: now),
                          list: list.map { $0.isSpecial ? $0.displayName : $0.bareName }, mark: list?.isSpecial == false ? list?.mark?.text : nil,
                          color: list?.color, timer: running.contains(task.id), email: task.isFromEmail,
                          sublist: task.subtasks.filter { !$0.done }.count, progress: model.isInProgress(task),
                          project: list?.project(task.project)?.name)
    }

    struct Parsed: Encodable {
        var title: String
        var tokens: [String]
    }

    /// What quick add reads in what's being typed, for the chips under the field.
    func parse(_ text: String) -> Parsed {
        let q = Quick.parse(String(text.prefix(300)), lists: model.snap.lists, weekStart: model.snap.weekStart)
        return Parsed(title: q.title, tokens: q.tokens(lists: model.snap.lists).map(\.text))
    }

    struct Done: Encodable {
        var ok = true
        var said: String?
        var added: State.Task?
        var state: State
    }

    private func perform(_ verb: String, _ f: [String: Any], at now: Date) -> PhoneResponse {
        let snap = model.snap
        var said: String?
        var added: State.Task?
        func task() -> TaskModel? { (f["id"] as? String).flatMap { snap.task($0) } }
        switch verb {
        case "add":
            guard let text = (f["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .json(["error": "nothing to add"], status: 400)
            }
            let q = Quick.parse(String(text.prefix(500)), lists: snap.lists, weekStart: snap.weekStart)
            var draft = q.draft(source: "iphone")
            let chosen = q.listId != nil || q.newList != nil || q.idea
            if !chosen, let list = (f["list"] as? String).flatMap({ snap.list($0) }) {
                draft.listId = list.id
            } else if !chosen, model.suggestWhileTyping, let guess = model.suggestion(for: draft.title) {
                draft.listId = guess.list.id
            }
            let id = model.store.add(draft)
            if let ask = q.timer, let made = model.snap.task(id) {
                model.timers.start(task: made, minutes: ask.minutes.map(Double.init), stopwatch: ask.stopwatch)
            }
            if let made = model.snap.task(id) {
                added = phoneTask(made, snap: model.snap, now: now, running: Set(model.timers.timers.compactMap(\.taskId)))
                said = "added to " + (model.snap.list(made.listId).map { $0.isSpecial ? $0.displayName : $0.bareName } ?? "inbox")
            }
        case "done":
            guard let t = task() else { return .json(["error": "that's gone"], status: 404) }
            if !t.done { model.store.toggle([t.id]) }
            said = "checked off"
        case "undone":
            guard let t = task() else { return .json(["error": "that's gone"], status: 404) }
            if t.done { model.store.toggle([t.id]) }
        case "remove", "delete":
            guard let t = task() else { return .json(["error": "that's gone"], status: 404) }
            if verb == "delete" { deleted = model.store.doc[task: t.id] }
            model.store.delete([t.id])
            said = verb == "delete" ? "deleted" : "removed"
        case "restore":
            guard let entry = deleted, let id = entry["id"] as? String, model.snap.task(id) == nil else { return .json(["error": "nothing to restore"], status: 404) }
            deleted = nil
            model.store.change("restore") { $0[task: id] = entry }
            said = "restored"
        case "progress":
            guard let t = task() else { return .json(["error": "that's gone"], status: 404) }
            if f["timer"] as? Bool == true {
                model.startInProgress(t.id)
                said = "in progress, timer going"
            } else {
                let was = model.isInProgress(t)
                model.toggleInProgress(t.id)
                said = was ? "not in progress" : "in progress"
            }
        case "timer":
            let minutes = (f["minutes"] as? NSNumber)?.doubleValue
            if let minutes, !(minutes > 0 && minutes <= 24 * 60) { return .json(["error": "a timer from a minute to a day"], status: 400) }
            let label = (f["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
            model.timers.start(task: task(), minutes: minutes, stopwatch: f["stopwatch"] as? Bool ?? false,
                               label: label.map(String.init).flatMap { $0.isEmpty ? nil : $0 })
        case "pause":
            guard let id = f["id"] as? String, model.timers.timers.contains(where: { $0.id == id }) else { return .json(["error": "that's gone"], status: 404) }
            model.timers.togglePause(id)
        case "stop":
            guard let id = f["id"] as? String, model.timers.timers.contains(where: { $0.id == id }) else { return .json(["error": "that's gone"], status: 404) }
            model.timers.stop(id)
        case "more":
            guard let id = f["id"] as? String, model.timers.timers.contains(where: { $0.id == id }) else { return .json(["error": "that's gone"], status: 404) }
            model.timers.extend(id, minutes: min(max((f["minutes"] as? NSNumber)?.doubleValue ?? 5, 1), 60))
        case "stoptimer":
            guard let t = task(), let running = model.timers.timer(for: t.id) else { return .json(["error": "no timer on it"], status: 404) }
            model.timers.stop(running.id)
            said = "timer stopped"
        case "dismiss":
            model.timers.dismissRinging()
        case "snooze":
            model.timers.snooze(minutes: 5)
        default:
            return .json(["error": "not something toyl does"], status: 400)
        }
        return .json(Done(said: said, added: added, state: state(at: now)))
    }

    // MARK: - keys and codes

    static func setCookie(_ key: String) -> String { "\(cookie)=\(key); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict" }

    static func hash(_ key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    static func qrCode(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage,
              let mask = CIFilter(name: "CIMaskToAlpha", parameters: [kCIInputImageKey: code.applyingFilter("CIColorInvert")])?.outputImage
        else { return nil }
        return CIContext().createCGImage(mask, from: code.extent)
    }
}
