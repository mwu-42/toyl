import AppKit
import Carbon
import FoundationModels

/// Linking toyl to the agents that can work on it: the `toyl` command (for anything with a
/// shell), and its MCP server in Claude Desktop, Claude Code and Muse Code. Each is a button in
/// settings; nothing's linked till it's pressed (bar the command, which is only a link in
/// ~/.local/bin).
enum Integrations {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - the command

    static var commandInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.commandLink.path)) == Paths.program.path
    }

    /// ~/.local/bin/toyl, pointing at the app's program (only for the installed app's real list).
    static func installCommand() throws {
        let files = FileManager.default
        try files.createDirectory(at: Paths.commandLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? files.destinationOfSymbolicLink(atPath: Paths.commandLink.path)) != nil || files.fileExists(atPath: Paths.commandLink.path) {
            try files.removeItem(at: Paths.commandLink)
        }
        try files.createSymbolicLink(at: Paths.commandLink, withDestinationURL: Paths.program)
    }

    static func installCommandIfNeeded() {
        guard Paths.isReal, Paths.program.path.hasPrefix(Paths.installedApp.path), !commandInstalled else { return }
        // Only where there's nothing else called toyl already.
        let existing = (try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.commandLink.path))
        guard existing == nil || existing!.contains("toyl.app"), !(FileManager.default.fileExists(atPath: Paths.commandLink.path) && existing == nil) else { return }
        try? installCommand()
    }

    // MARK: - Claude Desktop

    static var claudeDesktopConfig: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var claudeDesktopConnected: Bool {
        guard let data = try? Data(contentsOf: claudeDesktopConfig),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers["toyl"] != nil
    }

    /// Adds toyl to Claude Desktop's MCP servers (keeping a copy of its settings as they were).
    /// Claude needs reopening to see it.
    static func connectClaudeDesktop() throws {
        let files = FileManager.default
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeDesktopConfig) {
            guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw Ops.Failure("claude's settings file can't be read, so toyl left it alone")
            }
            json = read
            try? data.write(to: claudeDesktopConfig.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.before-toyl.json"))
        } else {
            try files.createDirectory(at: claudeDesktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers["toyl"] = ["command": Paths.program.path, "args": ["mcp"]]
        json["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: claudeDesktopConfig, options: .atomic)
    }

    // MARK: - Claude Code

    static var claudeProgram: URL? {
        [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var claudeCodeConnected: Bool {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers["toyl"] != nil
    }

    /// `claude mcp add --scope user toyl -- <toyl> mcp`: toyl's tools in every Claude Code session.
    static func connectClaudeCode() throws {
        guard let claude = claudeProgram else { throw Ops.Failure("can't find claude code's `claude` command") }
        let process = Process()
        process.executableURL = claude
        process.arguments = ["mcp", "add", "--scope", "user", "toyl", "--", Paths.program.path, "mcp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let said = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if said.contains("already exists") { return }
            throw Ops.Failure("claude code said: " + said.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    // MARK: - Muse Code

    static var museConfig: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        return base.appendingPathComponent("muse/settings.json")
    }

    static var museCodeConnected: Bool {
        guard let data = try? Data(contentsOf: museConfig),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = json["mcp_servers"] as? [String: Any] else { return false }
        return servers["toyl"] != nil
    }

    /// Adds toyl to Muse Code's MCP servers (its settings.json: `schema_version` 1, `mcp_servers`).
    static func connectMuseCode() throws {
        var json: [String: Any] = ["schema_version": 1]
        if let data = try? Data(contentsOf: museConfig) {
            guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw Ops.Failure("muse code's settings can't be read, so toyl left them alone")
            }
            json = read
            try? data.write(to: museConfig.deletingLastPathComponent().appendingPathComponent("settings.before-toyl.json"))
        } else {
            try FileManager.default.createDirectory(at: museConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var servers = json["mcp_servers"] as? [String: Any] ?? [:]
        servers["toyl"] = ["command": Paths.program.path, "args": ["mcp"]]
        json["mcp_servers"] = servers
        if json["schema_version"] == nil { json["schema_version"] = 1 }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: museConfig, options: .atomic)
    }

    // MARK: - opening at login

    static var opensAtLogin: Bool { SMAppServiceBridge.isEnabled }
}

import ServiceManagement

enum SMAppServiceBridge {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("toyl: couldn't change opening at login: \(error.localizedDescription)")
        }
    }
}

/// A shortcut that works from any app (⌃⌥T for quick entry), through Carbon's hot keys, which
/// need no permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false

    init?(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
        Self.install()
        Self.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x746F_796C), id: id)    // 'toyl'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { HotKey.actions[key]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Apple's on-device model, where Apple Intelligence is on: autosort's second opinion, and
/// breaking a task into steps. Nothing leaves the Mac.
enum OnDevice {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// The list a task belongs in, from your lists and a few of each one's tasks; nil if none fits.
    static func list(for title: String, among lists: [ListModel], examples: [String: [String]]) async -> String? {
        guard isAvailable, !lists.isEmpty else { return nil }
        let instructions = """
            You file to-do items into one of a person's lists. You're given the lists, each with a few of its items, \
            then a new item. Reply with the exact name of the list it belongs in, or NONE if none clearly fits. \
            Reply with the list's name only.
            """
        var prompt = "Lists:\n"
        for list in lists {
            let some = (examples[list.id] ?? []).prefix(6).joined(separator: "; ")
            prompt += "- \(list.name)" + (some.isEmpty ? "" : ": " + some) + "\n"
        }
        prompt += "New item: \(title)"
        let session = LanguageModelSession(instructions: instructions)
        guard let response = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 24)) else { return nil }
        let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.*-")))
        guard answer.uppercased() != "NONE" else { return nil }
        return lists.first { $0.name.caseInsensitiveCompare(answer) == .orderedSame }?.id
            ?? lists.first { !$0.handle.isEmpty && TodQuick.words(answer).joined() == $0.handle }?.id
    }

    /// Whether an email needs doing, and if so the to-do for it (lower case, a few words); nil if not.
    static func mailTask(_ message: MailMessage) async -> String? {
        guard isAvailable else { return nil }
        let instructions = """
            You read one email and decide if the reader must do something about it soon: pick something up, pay, \
            submit, sign, register, reply to a person who's waiting, or go somewhere at a set time. Newsletters, \
            receipts, notices, ads, codes and things just for information don't count. If it needs doing, reply \
            with a to-do for it: under 8 words, all lower case, starting with a verb. Otherwise reply NONE.
            """
        let prompt = "From: \(message.from) <\(message.address)>\nSubject: \(message.subject)\n\(message.snippet.prefix(400))"
        let session = LanguageModelSession(instructions: instructions)
        guard let response = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 30)) else { return nil }
        // Its first line only (it sometimes says more after).
        let line = response.content.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.*-")))
        guard !answer.isEmpty, !answer.uppercased().hasPrefix("NONE"), answer.count <= 80 else { return nil }
        return answer.lowercased()
    }

    /// Three to six small next steps for a task, in lower case.
    static func steps(for title: String, notes: String) async -> [String] {
        guard isAvailable else { return [] }
        let instructions = """
            You break a to-do item into 3 to 6 small, concrete next steps a student could start right away. \
            One step per line, all lower case, no numbering or bullets, no punctuation at the end, each under 8 words. \
            Reply with the steps only.
            """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "To-do: \(title)" + (notes.isEmpty ? "" : "\nNotes: \(notes.prefix(500))")
        guard let response = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.4, maximumResponseTokens: 120)) else { return [] }
        return response.content.split(whereSeparator: \.isNewline).map { line in
            line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(?:[-*•]|\d+[.)])\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                .lowercased()
        }
        .filter { !$0.isEmpty }
        .prefix(6)
        .map { $0 }
    }
}
