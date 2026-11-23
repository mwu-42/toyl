import CryptoKit
import Foundation

// Google Calendar, directly: toyl signs in to your Google account itself (no Apple Calendar in
// between), reads your calendars, their labels and their events, and adds events where your
// calendar rules say (see `CalendarRules`).

// MARK: - what google's calendar holds

/// One of a calendar's labels (Google's labels, which replaced its eleven event colors).
struct GLabel: Equatable, Hashable, Codable {
    let id: String
    var name: String
    var color: String
}

struct GCalendar: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var color: String
    var primary: Bool
    /// Shown in Google's own list (picked, and not hidden there).
    var shownInGoogle: Bool
    var accessRole: String
    var labels: [GLabel]

    var writable: Bool { accessRole == "owner" || accessRole == "writer" }

    func label(named name: String) -> GLabel? {
        let key = TodQuick.words(name).joined()
        return labels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? labels.first { TodQuick.words($0.name).joined() == key }
    }

    init?(entry e: [String: Any]) {
        guard let id = e["id"] as? String else { return nil }
        self.id = id
        name = e["summaryOverride"] as? String ?? e["summary"] as? String ?? id
        color = (e["backgroundColor"] as? String ?? "#8c8c8c").lowercased()
        primary = e["primary"] as? Bool ?? false
        shownInGoogle = (e["selected"] as? Bool ?? false) && !(e["hidden"] as? Bool ?? false)
        accessRole = e["accessRole"] as? String ?? "reader"
        labels = []
    }
}

struct GEvent: Identifiable, Equatable {
    let id: String
    let calendarId: String
    var title: String
    var description: String
    var location: String
    var start: Date
    var end: Date
    var allDay: Bool
    var labelId: String?
    var status: String
    var updated: Date?
    /// The task it's for, if toyl put it there (kept out of sight, in its private properties).
    var taskId: String?
    var recurring: Bool
    /// The event on calendar.google.com.
    var link: String?

    var day: String { Day.string(start) }

    init?(entry e: [String: Any], calendarId: String) {
        guard let id = e["id"] as? String, let start = e["start"] as? [String: Any], let end = e["end"] as? [String: Any] else { return nil }
        if let date = start["date"] as? String, let from = Day.date(date) {
            allDay = true
            self.start = from
            self.end = (end["date"] as? String).flatMap(Day.date) ?? from.addingTimeInterval(86400)
        } else if let from = GoogleTime.date(start["dateTime"]), let to = GoogleTime.date(end["dateTime"]) {
            allDay = false
            self.start = from
            self.end = to
        } else {
            return nil
        }
        self.id = id
        self.calendarId = calendarId
        title = e["summary"] as? String ?? ""
        description = e["description"] as? String ?? ""
        location = e["location"] as? String ?? ""
        labelId = (e["eventLabelId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        status = e["status"] as? String ?? "confirmed"
        updated = GoogleTime.date(e["updated"])
        taskId = ((e["extendedProperties"] as? [String: Any])?["private"] as? [String: Any])?["toylTask"] as? String
        recurring = e["recurringEventId"] != nil
        link = e["htmlLink"] as? String
    }
}

/// An event to add, ready for Google: written the owner's way already (see `CalendarStyle`).
struct EventPlan: Equatable {
    var title: String
    var calendarId: String
    var labelId: String?
    var day: String
    var start: String?       // "HH:MM", nil all day
    var end: String?
    var allDay: Bool
    var location: String
    var description: String
    var taskId: String?

    var startDate: Date? { allDay ? Day.date(day) : Day.moment(day, start) }

    var endDate: Date? {
        if allDay { return Day.date(day).flatMap { Day.calendar.date(byAdding: .day, value: 1, to: $0) } }
        guard let from = startDate, var to = Day.moment(day, end) else { return nil }
        // Ending earlier on the clock than it starts: past midnight.
        if to <= from { to = Day.calendar.date(byAdding: .day, value: 1, to: to) ?? to }
        return to
    }

    /// Google's event: no reminders (unless asked: none's ever added here), no link in it, the
    /// task it's for tucked away in its private properties.
    var body: [String: Any] {
        var body: [String: Any] = ["summary": title, "reminders": ["useDefault": false]]
        if !description.isEmpty { body["description"] = description }
        if !location.isEmpty { body["location"] = location }
        if let labelId { body["eventLabelId"] = labelId }
        if let taskId { body["extendedProperties"] = ["private": ["toylTask": taskId]] }
        let zone = TimeZone.autoupdatingCurrent.identifier
        if allDay {
            body["start"] = ["date": day]
            body["end"] = ["date": Day.adding(1, to: day) ?? day]
        } else if let from = startDate, let to = endDate {
            body["start"] = ["dateTime": GoogleTime.string(from), "timeZone": zone]
            body["end"] = ["dateTime": GoogleTime.string(to), "timeZone": zone]
        }
        return body
    }
}

enum GoogleTime {
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    static func string(_ date: Date) -> String { plain.string(from: date) }

    /// "2026-11-20T08:00:00Z", as Microsoft Graph's filters want it.
    static func utc(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - signing in

/// Signing in to Google the way a desktop app does: Google's page in your browser, and its
/// answer back to toyl on this Mac (a listener on 127.0.0.1 for that one answer), PKCE-checked.
/// It needs an OAuth client of your own (a free one, from Google Cloud: see settings).
enum GoogleAuth {
    struct Client: Codable, Equatable {
        var id: String
        var secret: String
    }

    struct Token: Codable {
        var access: String
        var refresh: String?
        var expires: Date
        /// What Google allowed (space-separated), when it said.
        var scope: String?
    }

    enum Failure: Error, CustomStringConvertible {
        case noClient, signedOut, expired, denied(String), said(String)

        var description: String {
            switch self {
            case .noClient: return "toyl needs your google oauth client first (settings › google calendar)"
            case .signedOut: return "toyl isn't signed in to google calendar (settings › google calendar › connect)"
            case .expired: return "google signed toyl out (apps in google's testing mode are, every week): connect again"
            case .denied(let why): return "google said no: \(why)"
            case .said(let what): return what
            }
        }
    }

    /// Reading every calendar (and its labels), and changing events on them; and reading Gmail,
    /// once pulling email from it is on.
    static var scopes: [String] {
        let calendar = ["https://www.googleapis.com/auth/calendar.readonly", "https://www.googleapis.com/auth/calendar.events"]
        return MailSettings.load().gmail ? calendar + [Gmail.scope] : calendar
    }

    /// Whether the sign-in covers this (Gmail, say).
    static func allows(_ scope: String) -> Bool { token?.scope?.split(separator: " ").contains { $0 == scope } ?? false }
    static var authEndpoint: String { env("TOYL_GOOGLE_AUTH") ?? "https://accounts.google.com/o/oauth2/v2/auth" }
    static var tokenEndpoint: String { env("TOYL_GOOGLE_TOKEN") ?? "https://oauth2.googleapis.com/token" }

    static var client: Client? { Secrets.decode("google-client", as: Client.self) }
    static var token: Token? { Secrets.decode("google-token", as: Token.self) }
    static var isConnected: Bool { client != nil && token?.refresh != nil }

    static func setClient(_ client: Client) {
        Secrets.encode(client, "google-client")
        Secrets.delete("google-token")
    }

    static func signOut() { Secrets.delete("google-token") }

    /// A client from what Google gave you: its downloaded JSON (`{"installed": {…}}`), or the ID
    /// and secret, pasted.
    static func client(from text: String) -> Client? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let inner = json["installed"] as? [String: Any] ?? json["web"] as? [String: Any] ?? json
            if let id = inner["client_id"] as? String, let secret = inner["client_secret"] as? String, !id.isEmpty, !secret.isEmpty {
                return Client(id: id, secret: secret)
            }
        }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        if parts.count == 2, parts[0].hasSuffix(".apps.googleusercontent.com") { return Client(id: parts[0], secret: parts[1]) }
        return nil
    }

    /// Signs in: `open` shows Google's page (in the browser); the answer comes back within five
    /// minutes, or it gives up.
    static func signIn(open: @escaping @Sendable (URL) -> Void) async throws {
        guard let client else { throw Failure.noClient }
        let loopback = try Loopback()
        let redirect = "http://127.0.0.1:\(loopback.port)"
        let verifier = randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomURLSafe(24)
        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id), URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else { throw Failure.said("couldn't make google's sign-in link") }
        open(url)
        let page = """
            <!doctype html><meta charset="utf-8"><title>toyl</title>
            <body style="font: 20px 'Times New Roman', serif; background: #fbfbfa; color: #1d1d1c; margin: 18vh auto; max-width: 30em">
            <p>toyl has its answer from google.</p><p style="color: #737370">you can close this tab.</p></body>
            """
        let answer = await Task.detached { loopback.answer(within: 300, page: page) }.value
        guard let answer else { throw Failure.said("no answer from google, so toyl stopped waiting (five minutes)") }
        if let error = answer["error"] { throw Failure.denied(error.replacingOccurrences(of: "_", with: " ")) }
        guard answer["state"] == state, let code = answer["code"] else { throw Failure.said("google's answer didn't match what toyl asked") }
        let json = try await post(tokenEndpoint, ["code": code, "client_id": client.id, "client_secret": client.secret,
                                                  "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier])
        guard let access = json["access_token"] as? String else { throw Failure.said("google sent no access token") }
        let token = Token(access: access, refresh: json["refresh_token"] as? String,
                          expires: Date().addingTimeInterval((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600),
                          scope: json["scope"] as? String ?? scopes.joined(separator: " "))
        guard token.refresh != nil else { throw Failure.said("google sent no refresh token: remove toyl from your google account's third-party access, then connect again") }
        Secrets.encode(token, "google-token")
    }

    /// An access token that's good for a while yet, renewed if it isn't.
    static func accessToken() async throws -> String {
        guard let client else { throw Failure.noClient }
        guard var token else { throw Failure.signedOut }
        if token.expires.timeIntervalSinceNow > 90 { return token.access }
        guard let refresh = token.refresh else { throw Failure.signedOut }
        do {
            let json = try await post(tokenEndpoint, ["client_id": client.id, "client_secret": client.secret,
                                                      "refresh_token": refresh, "grant_type": "refresh_token"])
            guard let access = json["access_token"] as? String else { throw Failure.said("google sent no access token") }
            token.access = access
            token.expires = Date().addingTimeInterval((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
            if let renewed = json["refresh_token"] as? String { token.refresh = renewed }
            Secrets.encode(token, "google-token")
            return access
        } catch Failure.expired {
            signOut()
            throw Failure.expired
        }
    }

    /// Makes the next call get a fresh token (Google turned the last one down).
    static func forgetAccess() {
        guard var token else { return }
        token.expires = .distantPast
        Secrets.encode(token, "google-token")
    }

    private static func post(_ address: String, _ form: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw Failure.said("bad address \(address)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.key)=\(escape($0.value))" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let error = json["error"] as? String ?? "http \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            if error == "invalid_grant" { throw Failure.expired }
            throw Failure.said("google said: " + ((json["error_description"] as? String) ?? error).lowercased())
        }
        return json
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
    }

    private static func randomURLSafe(_ count: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in letters.randomElement(using: &generator)! })
    }

    static func env(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]
        return value?.isEmpty == false ? value : nil
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A listener on 127.0.0.1 for Google's one answer after signing in.
final class Loopback: @unchecked Sendable {
    let port: UInt16
    private let socket: Int32

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GoogleAuth.Failure.said("couldn't listen for google's answer") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw GoogleAuth.Failure.said("couldn't listen for google's answer")
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        socket = fd
        port = UInt16(bigEndian: assigned.sin_port)
    }

    deinit { close(socket) }

    /// The query of the first request that carries Google's answer (a code, or an error),
    /// answered with `page`; nil if none comes in time. Anything else (a favicon) gets a 404.
    func answer(within seconds: TimeInterval, page: String) -> [String: String]? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var waiting = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, Int32(max(min(deadline.timeIntervalSinceNow, 1), 0.05) * 1000)) > 0 else { continue }
            let client = accept(socket, nil, nil)
            guard client >= 0 else { continue }
            defer { close(client) }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = read(client, &buffer, buffer.count)
            guard count > 0, let request = String(bytes: buffer[0..<count], encoding: .utf8) else { continue }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
            let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            guard values["code"] != nil || values["error"] != nil else {
                send(client, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                continue
            }
            send(client, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page)
            return values
        }
        return nil
    }

    private func send(_ client: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes[sent...].withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            guard wrote > 0 else { return }
            sent += wrote
        }
    }
}

// MARK: - the calendar API

enum GoogleCalendarAPI {
    static var base: String { GoogleAuth.env("TOYL_GOOGLE_API") ?? "https://www.googleapis.com/calendar/v3" }

    /// Every calendar in your list, with its labels (where Google lets toyl read them).
    static func calendars() async throws -> [GCalendar] {
        var found: [GCalendar] = []
        var page: String?
        repeat {
            var query = ["maxResults": "250", "showHidden": "true"]
            if let page { query["pageToken"] = page }
            let json = try await call("GET", "/users/me/calendarList", query: query)
            found += (json["items"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(GCalendar.init(entry:)) }
            page = json["nextPageToken"] as? String
        } while page != nil
        for index in found.indices where found[index].accessRole == "owner" || found[index].accessRole == "writer" {
            guard let json = try? await call("GET", "/calendars/\(segment(found[index].id))"),
                  let labels = (json["labelProperties"] as? [String: Any])?["eventLabels"] as? [Any] else { continue }
            found[index].labels = labels.compactMap { item in
                guard let label = item as? [String: Any], let id = label["id"] as? String else { return nil }
                return GLabel(id: id, name: label["name"] as? String ?? "", color: (label["backgroundColor"] as? String ?? "#8c8c8c").lowercased())
            }
        }
        return found
    }

    /// A calendar's events between two moments, each repeat on its own.
    static func events(_ calendar: String, from: Date, to: Date) async throws -> [GEvent] {
        var found: [GEvent] = []
        var page: String?
        repeat {
            var query = ["timeMin": GoogleTime.string(from), "timeMax": GoogleTime.string(to), "singleEvents": "true",
                         "orderBy": "startTime", "maxResults": "2500"]
            if let page { query["pageToken"] = page }
            let json = try await call("GET", "/calendars/\(segment(calendar))/events", query: query, labels: true)
            found += (json["items"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap { GEvent(entry: $0, calendarId: calendar) } }
            page = json["nextPageToken"] as? String
        } while page != nil
        return found
    }

    /// One event, or nil if it's gone.
    static func event(_ calendar: String, _ id: String) async throws -> GEvent? {
        do {
            let json = try await call("GET", "/calendars/\(segment(calendar))/events/\(segment(id))", labels: true)
            return GEvent(entry: json, calendarId: calendar)
        } catch CallFailure.gone {
            return nil
        }
    }

    static func insert(_ plan: EventPlan) async throws -> GEvent {
        let json = try await call("POST", "/calendars/\(segment(plan.calendarId))/events", body: plan.body, labels: true)
        guard let event = GEvent(entry: json, calendarId: plan.calendarId) else { throw GoogleAuth.Failure.said("google didn't say what it made") }
        return event
    }

    static func patch(_ calendar: String, _ id: String, _ body: [String: Any]) async throws -> GEvent? {
        let json = try await call("PATCH", "/calendars/\(segment(calendar))/events/\(segment(id))", body: body, labels: true)
        return GEvent(entry: json, calendarId: calendar)
    }

    static func delete(_ calendar: String, _ id: String) async throws {
        do {
            _ = try await call("DELETE", "/calendars/\(segment(calendar))/events/\(segment(id))")
        } catch CallFailure.gone {
            // Gone already.
        }
    }

    enum CallFailure: Error { case gone }

    /// One call, signed. Calls on events carry `eventLabelVersion=1`, so labels come and go
    /// with them (Google ignores the old colors then).
    private static func call(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil,
                             labels: Bool = false, again: Bool = true) async throws -> [String: Any] {
        guard var components = URLComponents(string: base + path) else { throw GoogleAuth.Failure.said("bad address") }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if labels { items.append(URLQueryItem(name: "eventLabelVersion", value: "1")) }
        if !items.isEmpty { components.percentEncodedQuery = items.map { "\($0.name)=\(GoogleAuth.escape($0.value ?? ""))" }.joined(separator: "&") }
        guard let url = components.url else { throw GoogleAuth.Failure.said("bad address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + (try await GoogleAuth.accessToken()), forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, again {
            GoogleAuth.forgetAccess()
            return try await call(method, path, query: query, body: body, labels: labels, again: false)
        }
        if status == 404 || status == 410 { throw CallFailure.gone }
        let json = data.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "http \(status)"
            throw GoogleAuth.Failure.said("google calendar said: " + message.lowercased())
        }
        return json
    }

    /// A calendar or event id, safe in a path (holiday calendars have "#" in theirs).
    private static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@"))) ?? id
    }
}

/// Holds what async work came to, for `waitFor`.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Waits for async work from code that can't (the command line, the MCP server).
func waitFor<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}
