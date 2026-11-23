import CryptoKit
import Foundation

// Pulling important email into toyl: Gmail (through the Google sign-in toyl already has) and
// Outlook (through Microsoft's). Only what needs doing comes in: a package to pick up (QTrak's
// notices and the like), something due, something to sign, pay, submit or answer. Newsletters,
// receipts, codes and the rest stay in the inbox. What comes in is flagged: `source: "email"` and
// an `email` link back to the message.

/// Which inboxes, and what's been looked at already. In toyl's folder (`mail.json`): no secrets
/// here, the sign-ins are in the keychain.
struct MailSettings: Codable, Equatable {
    var gmail = false
    var outlook = false
    /// Ask Apple's on-device model about mail the inbox flagged that the rules don't cover.
    var ask = true
    /// When the inboxes were last read (all of them, without trouble). Cleared when one's turned
    /// on, so its first pull looks back `days`.
    var lastPull: Date?
    /// Messages already judged (pulled or passed over), newest last.
    var seen: [String] = []
    /// How far back the first pull looks.
    var days = 3

    static func load() -> MailSettings {
        guard let data = try? Data(contentsOf: Paths.mail), let settings = try? JSONDecoder.toyl.decode(MailSettings.self, from: data) else { return MailSettings() }
        return settings
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.toyl.encode(self) { try? data.write(to: Paths.mail, options: .atomic) }
    }
}

extension JSONEncoder {
    static var toyl: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var toyl: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A message, as much as toyl needs to judge it.
struct MailMessage: Equatable, Sendable {
    let account: String       // "gmail" or "outlook"
    let id: String
    let from: String          // the sender's name, else address
    let address: String
    let subject: String
    let snippet: String
    let received: Date
    let link: String?
    /// The inbox says it matters: Gmail's important, Outlook's focused or high importance.
    let flagged: Bool
    /// A mailing list or a newsletter: an unsubscribe header, or promotions and the like.
    let bulk: Bool

    var key: String { account + ":" + id }
}

/// What an important message becomes.
struct MailTask: Equatable {
    let message: MailMessage
    let title: String
    let due: String?
    /// Why it came in: "package", "to do", or "apple intelligence".
    let why: String

    var draft: TaskDraft {
        var draft = TaskDraft(title: title)
        draft.listId = ListModel.inbox
        draft.due = due
        draft.source = "email"
        draft.notes = "✉ " + (message.from.isEmpty ? message.address : message.from) + ": " + message.subject
        draft.email = MailLink(account: message.account, id: message.id, from: message.from.isEmpty ? message.address : message.from,
                               subject: message.subject, link: message.link)
        return draft
    }
}

// MARK: - what counts

/// The rules for what's important. Rules first (they're quick and sure); then, for mail the
/// inbox itself flagged from a person, Apple's on-device model, if it's on.
enum MailRules {
    static func judge(_ m: MailMessage) -> MailTask? {
        let subject = m.subject.lowercased()
        let all = [m.from, m.address, m.subject, m.snippet].joined(separator: " ").lowercased()
        if isPackage(all) {
            return MailTask(message: m, title: packageTitle(all), due: Day.string(m.received), why: "package")
        }
        if matches(never, all) { return nil }
        // A list or a newsletter only counts when it's the school's, and says so plainly.
        if m.bulk, !m.address.lowercased().hasSuffix(".edu") { return nil }
        guard matches(action, subject) else { return nil }
        var title = tidy(m.subject)
        // "your hold is ready for pickup" → "pick up hold".
        if let thing = first(#"^(?:your |the )?(.{2,40}?) (?:is|are) (?:now )?(?:ready|available) for pick ?up"#, title) { title = "pick up " + thing }
        guard !title.isEmpty else { return nil }
        return MailTask(message: m, title: title, due: dueDay(in: m.subject + " " + m.snippet, received: m.received), why: "to do")
    }

    /// Worth asking the on-device model about: flagged by the inbox, from a person, not a list.
    static func worthAsking(_ m: MailMessage) -> Bool {
        m.flagged && !m.bulk && !matches(automated, m.address.lowercased()) && !matches(never, (m.subject + " " + m.snippet).lowercased())
    }

    // A package waiting: QTrak's notices, a mail room, a locker, a front desk.
    static func isPackage(_ text: String) -> Bool {
        if matches([#"\bq-?trak\b"#], text) { return true }
        return matches([#"\b(package|parcel|delivery|mail item)s?\b"#], text)
            && matches([#"pick ?up|pickup|ready for (you|collection)|waiting for you|available for|mail ?room|mail (center|services)|front desk|locker|held for you|on hold for you"#], text)
    }

    static func packageTitle(_ text: String) -> String {
        let place = first(#"(?:pick(?:ed)? ?up|pickup|collect(?:ed)?|waiting|available|ready|held)[^.\n]{0,40}?\bat (?:the )?([a-z0-9&'’ .-]{3,40}?)(?=[.,;:!)\n]|\s+(?:between|from|during|before|by|with|and|on|until|if|using|please|today|tomorrow)\b|$)"#, text)
        let qtrak = matches([#"\bq-?trak\b"#], text)
        var title = "pick up package"
        if let place, !place.isEmpty { title += " at " + place.trimmingCharacters(in: .whitespaces) }
        else if qtrak { title += " (qtrak)" }
        return title
    }

    /// Never a task: codes, sign-ins, receipts, shipping news, newsletters.
    static let never = [
        #"verification code|security code|one.time (pass)?code|\botp\b|2fa|two.factor|sign.in (attempt|alert)|new sign.in|login alert"#,
        #"password reset|reset your password|confirm your (email|account|subscription)|verify your"#,
        #"receipt|order confirm|has shipped|\bshipped\b|out for delivery|on its way|tracking number"#,
        #"newsletter|digest|webinar|% off|\bsale\b|deal of|promo code|black friday|cyber monday"#,
    ]

    /// Something to do, said in the subject.
    static let action = [
        #"\baction (required|needed|requested)\b"#,
        #"\b(response|reply|signature|rsvp) (required|needed|requested)\b"#,
        #"\brsvp\b"#,
        #"\bplease (respond|reply|confirm|sign|complete|submit|review|rsvp|pay|register|schedule|return|fill)\b"#,
        #"\b(is|are|was) due\b"#,
        #"\bdue (today|tonight|tomorrow|soon|by|on|this|next|mon|tue|wed|thu|fri|sat|sun|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"#,
        #"\bdeadline\b"#,
        #"\boverdue\b"#,
        #"\b(payment|bill|invoice|balance|fee|tuition|rent)s? (is |are )?(due|past due|failed|required|reminder)\b"#,
        #"\bexpir(es|ing) (soon|today|tomorrow|in)\b"#,
        #"\b(ready for|available for) pick ?up\b"#,
        #"\b(prescription|hold|item|book)s? (is |are )?ready\b"#,
        #"\bappointment (reminder|tomorrow|today|confirm)"#,
        #"\b(complete|submit|sign|finish|confirm|renew|schedule|return) (your|the)\b"#,
        #"\binterview\b"#,
        #"\b(final|last) reminder\b"#,
    ]

    /// Mail no person wrote.
    static let automated = [#"no-?reply|donotreply|do-not-reply|notifications?@|mailer|news(letter)?@|marketing|updates?@|info@|hello@|team@"#]

    /// The subject as a task: tags like "re:", "action required:" and "[list]" taken off, lower case.
    static func tidy(_ subject: String) -> String {
        var text = subject.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        let prefix = #"^\s*(re|fw|fwd|action (required|needed|requested)|reminder|final reminder|last reminder|important|urgent|time.sensitive|response (required|needed))\s*[:\-–|!]\s*"#
        while let range = text.range(of: prefix, options: [.regularExpression, .caseInsensitive]) { text.removeSubrange(range) }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".:-–!")))
            .lowercased()
        return text.count > 90 ? String(text.prefix(90)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    /// "due fri", "by nov 30", "deadline: tomorrow": the day, read from when it was sent.
    static func dueDay(in text: String, received: Date) -> String? {
        let pattern = #"\b(?:due|by|before|deadline(?: is)?|until|expires?(?: on)?)\s*:?\s+((?:today|tonight|tomorrow|(?:this |next )?(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2}(?:st|nd|rd|th)?|\d{1,2}/\d{1,2}))"#
        guard var said = first(pattern, text.lowercased()) else { return nil }
        if said == "tonight" { said = "today" }
        guard let day = TodQuick.read(said, now: received, weekStart: 1).due else { return nil }
        return day >= Day.string(received) ? day : nil
    }

    static func matches(_ patterns: [String], _ text: String) -> Bool {
        patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// The first group of the first match.
    static func first(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - pulling

enum MailPull {
    struct Outcome {
        var found: [MailTask] = []
        var looked = 0
        var errors: [String] = []
        var seen: [String] = []
        /// Whether any inbox was read.
        var read = false
    }

    /// What's new in the inboxes that are on, judged; nothing's added (see `finish`). `ask` is
    /// the on-device model, for flagged mail the rules don't cover.
    static func fetch(snap: Snapshot, now: Date = Date(), ask: ((MailMessage) async -> String?)? = nil) async -> Outcome {
        let settings = MailSettings.load()
        var outcome = Outcome()
        let earliest = now.addingTimeInterval(-Double(max(settings.days, 1)) * 86400)
        let since = max(settings.lastPull?.addingTimeInterval(-3600) ?? earliest, earliest)
        var messages: [MailMessage] = []
        if settings.gmail {
            if !GoogleAuth.isConnected {
                outcome.errors.append("gmail: connect google first")
            } else if !GoogleAuth.allows(Gmail.scope) {
                outcome.errors.append("gmail: connect google again to allow gmail")
            } else {
                do { messages += try await Gmail.recent(since: since); outcome.read = true } catch { outcome.errors.append("gmail: \(error)") }
            }
        }
        if settings.outlook {
            if Outlook.isConnected {
                do { messages += try await Outlook.recent(since: since); outcome.read = true } catch { outcome.errors.append("outlook: \(error)") }
            } else {
                outcome.errors.append("outlook: not connected")
            }
        }
        outcome.looked = messages.count
        let seen = Set(settings.seen)
        let pulled = Set(snap.tasks.compactMap { $0.email.map { $0.account + ":" + $0.id } })
        let open = Set(snap.tasks.filter { !$0.done }.map { $0.title.lowercased() })
        for message in messages.sorted(by: { $0.received < $1.received }) where !seen.contains(message.key) && !pulled.contains(message.key) {
            outcome.seen.append(message.key)
            var task = MailRules.judge(message)
            if task == nil, let ask, settings.ask, MailRules.worthAsking(message), let title = await ask(message) {
                task = MailTask(message: message, title: title, due: MailRules.dueDay(in: message.subject + " " + message.snippet, received: message.received),
                                why: "apple intelligence")
            }
            guard let task, !open.contains(task.title.lowercased()), !outcome.found.contains(where: { $0.title == task.title }) else { continue }
            outcome.found.append(task)
        }
        return outcome
    }

    /// Remembers what was looked at, so it's judged once.
    static func finish(_ outcome: Outcome, now: Date = Date()) {
        var settings = MailSettings.load()
        if outcome.read, outcome.errors.isEmpty { settings.lastPull = now }
        settings.seen = Array((settings.seen + outcome.seen).suffix(3000))
        settings.save()
    }
}

// MARK: - gmail

enum Gmail {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    static var base: String { GoogleAuth.env("TOYL_GMAIL_API") ?? "https://gmail.googleapis.com/gmail/v1" }

    /// The inbox since then, less promotions, social and forums.
    static func recent(since: Date) async throws -> [MailMessage] {
        let q = "in:inbox after:\(Int(since.timeIntervalSince1970)) -category:promotions -category:social -category:forums"
        let list = try await get("users/me/messages", ["q": q, "maxResults": "40"])
        let ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        var found: [MailMessage] = []
        for id in ids {
            let m = try await get("users/me/messages/\(id)", ["format": "metadata"],
                                  repeated: ["metadataHeaders": ["From", "Subject", "List-Unsubscribe", "List-Id", "Precedence"]])
            let headers = Dictionary(((m["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []).compactMap { h -> (String, String)? in
                guard let name = h["name"] as? String, let value = h["value"] as? String else { return nil }
                return (name.lowercased(), value)
            }, uniquingKeysWith: { first, _ in first })
            let labels = m["labelIds"] as? [String] ?? []
            let (name, address) = MailText.sender(headers["from"] ?? "")
            let received = (m["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let thread = m["threadId"] as? String ?? id
            found.append(MailMessage(account: "gmail", id: id, from: name, address: address, subject: headers["subject"] ?? "",
                                     snippet: MailText.plain(m["snippet"] as? String ?? ""), received: received,
                                     link: "https://mail.google.com/mail/u/0/#all/\(thread)", flagged: labels.contains("IMPORTANT"),
                                     bulk: headers["list-unsubscribe"] != nil || headers["list-id"] != nil
                                        || ["bulk", "list"].contains(headers["precedence"]?.lowercased() ?? "")
                                        || labels.contains { $0.hasPrefix("CATEGORY_") && $0 != "CATEGORY_PERSONAL" && $0 != "CATEGORY_UPDATES" }))
        }
        return found
    }

    private static func get(_ path: String, _ query: [String: String], repeated: [String: [String]] = [:], retried: Bool = false) async throws -> [String: Any] {
        var components = URLComponents(string: base + "/" + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + repeated.flatMap { key, values in values.map { URLQueryItem(name: key, value: $0) } }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + (try await GoogleAuth.accessToken()), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retried {
            GoogleAuth.forgetAccess()
            return try await get(path, query, repeated: repeated, retried: true)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "http \(status)"
            throw GoogleAuth.Failure.said(message.lowercased())
        }
        return json
    }
}

// MARK: - outlook

/// Outlook (Microsoft 365, or outlook.com) through Microsoft Graph: signing in as a desktop app
/// does (the browser, then an answer to toyl on this Mac, PKCE-checked), with an app you register
/// yourself in Microsoft Entra (its client ID; no secret).
enum Outlook {
    struct Client: Codable, Equatable {
        var id: String
        /// "common" (work, school or personal), "organizations", or a tenant like stanford.edu.
        var tenant: String
    }

    struct Token: Codable {
        var access: String
        var refresh: String?
        var expires: Date
    }

    static let scopes = "offline_access User.Read Mail.Read"
    static var client: Client? { Secrets.decode("outlook-client", as: Client.self) }
    static var token: Token? { Secrets.decode("outlook-token", as: Token.self) }
    static var isConnected: Bool { client != nil && token?.refresh != nil }

    static var authBase: String { GoogleAuth.env("TOYL_MS_AUTH") ?? "https://login.microsoftonline.com/\(client?.tenant ?? "common")/oauth2/v2.0" }
    static var api: String { GoogleAuth.env("TOYL_GRAPH_API") ?? "https://graph.microsoft.com/v1.0" }

    static func setClient(_ client: Client) {
        Secrets.encode(client, "outlook-client")
        Secrets.delete("outlook-token")
    }

    static func signOut() { Secrets.delete("outlook-token") }

    /// A client ID as Entra shows it (a GUID), with a tenant after it if you like.
    static func client(from text: String) -> Client? {
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard let id = parts.first, id.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil else { return nil }
        return Client(id: id.lowercased(), tenant: parts.count > 1 ? parts[1] : "common")
    }

    static func signIn(open: @escaping @Sendable (URL) -> Void) async throws {
        guard let client else { throw GoogleAuth.Failure.said("toyl needs your outlook app's client id first (settings › email)") }
        let loopback = try Loopback()
        let redirect = "http://localhost:\(loopback.port)"
        let verifier = random(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = random(24)
        var components = URLComponents(string: authBase + "/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id), URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "prompt", value: "select_account"),
        ]
        guard let url = components.url else { throw GoogleAuth.Failure.said("couldn't make microsoft's sign-in link") }
        open(url)
        let page = """
            <!doctype html><meta charset="utf-8"><title>toyl</title>
            <body style="font: 20px 'Times New Roman', serif; background: #fbfbfa; color: #1d1d1c; margin: 18vh auto; max-width: 30em">
            <p>toyl has its answer from microsoft.</p><p style="color: #737370">you can close this tab.</p></body>
            """
        let answer = await Task.detached { loopback.answer(within: 300, page: page) }.value
        guard let answer else { throw GoogleAuth.Failure.said("no answer from microsoft, so toyl stopped waiting (five minutes)") }
        if let error = answer["error"] {
            throw GoogleAuth.Failure.denied((answer["error_description"] ?? error).replacingOccurrences(of: "+", with: " ").lowercased())
        }
        guard answer["state"] == state, let code = answer["code"] else { throw GoogleAuth.Failure.said("microsoft's answer didn't match what toyl asked") }
        let json = try await post(["client_id": client.id, "code": code, "redirect_uri": redirect, "grant_type": "authorization_code",
                                   "code_verifier": verifier, "scope": scopes])
        try keep(json)
    }

    static func accessToken() async throws -> String {
        guard let client else { throw GoogleAuth.Failure.said("outlook isn't set up") }
        guard let token else { throw GoogleAuth.Failure.said("outlook isn't connected") }
        if token.expires.timeIntervalSinceNow > 90 { return token.access }
        guard let refresh = token.refresh else { throw GoogleAuth.Failure.said("outlook isn't connected") }
        let json = try await post(["client_id": client.id, "refresh_token": refresh, "grant_type": "refresh_token", "scope": scopes])
        try keep(json)
        return json["access_token"] as? String ?? ""
    }

    private static func keep(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String else { throw GoogleAuth.Failure.said("microsoft sent no access token") }
        let token = Token(access: access, refresh: json["refresh_token"] as? String ?? self.token?.refresh,
                          expires: Date().addingTimeInterval((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600))
        Secrets.encode(token, "outlook-token")
    }

    private static func post(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: authBase + "/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.key)=\(GoogleAuth.escape($0.value))" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let error = json["error"] as? String ?? "http \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            if error == "invalid_grant" { signOut() }
            let said = (json["error_description"] as? String)?.split(separator: "\r\n").first.map(String.init) ?? error
            throw GoogleAuth.Failure.said("microsoft said: " + said.lowercased())
        }
        return json
    }

    /// The inbox since then.
    static func recent(since: Date) async throws -> [MailMessage] {
        var components = URLComponents(string: api + "/me/mailFolders/inbox/messages")!
        components.queryItems = [
            URLQueryItem(name: "$top", value: "40"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
            URLQueryItem(name: "$filter", value: "receivedDateTime ge " + GoogleTime.utc(since)),
            URLQueryItem(name: "$select", value: "id,subject,from,receivedDateTime,bodyPreview,importance,inferenceClassification,webLink"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "http \(status)"
            throw GoogleAuth.Failure.said(message.lowercased())
        }
        return (json["value"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let sender = (m["from"] as? [String: Any])?["emailAddress"] as? [String: Any]
            let address = sender?["address"] as? String ?? ""
            let focused = (m["inferenceClassification"] as? String)?.lowercased() != "other"
            return MailMessage(account: "outlook", id: id, from: sender?["name"] as? String ?? address, address: address,
                               subject: m["subject"] as? String ?? "", snippet: MailText.plain(m["bodyPreview"] as? String ?? ""),
                               received: GoogleTime.date(m["receivedDateTime"]) ?? Date(), link: m["webLink"] as? String,
                               flagged: focused || (m["importance"] as? String)?.lowercased() == "high",
                               bulk: !focused || MailRules.matches([#"newsletter|news@|marketing|promo"#], address.lowercased()))
        }
    }

    private static func random(_ count: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in letters.randomElement(using: &generator)! })
    }
}

enum MailText {
    /// "Name <address>" → (name, address).
    static func sender(_ header: String) -> (String, String) {
        if let open = header.lastIndex(of: "<"), let close = header.lastIndex(of: ">"), open < close {
            let name = header[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
            let address = String(header[header.index(after: open)..<close])
            return (name.isEmpty ? address : name, address)
        }
        let address = header.trimmingCharacters(in: .whitespaces)
        return (address, address)
    }

    /// Snippets come with HTML's entities: as plain text.
    static func plain(_ text: String) -> String {
        var out = text
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&#8217;", "’")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}
