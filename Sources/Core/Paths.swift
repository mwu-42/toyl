import Foundation

/// Where toyl keeps things. Everything lives in one folder, so the app, its command line, its
/// MCP server and Oyl all work on the same file:
///
///     ~/Library/Application Support/toyl/
///         toyl.json        the list itself (tod's format, grown: see AGENTS.md)
///         toyl.md          the same list as Markdown, kept up to date, and editable
///         AGENTS.md        how an AI (or a person) reads and changes it
///         calendar.json    the coming weeks' events, as the app last saw them
///         toyl.backup.json the file as it was, at most ten minutes ago
///         backups/         a copy a day, for a fortnight
///
/// `TOYL_HOME` points somewhere else, for trying things out without touching the real list.
enum Paths {
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["TOYL_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("toyl", isDirectory: true)
    }

    static var data: URL { home.appendingPathComponent("toyl.json") }
    static var backup: URL { home.appendingPathComponent("toyl.backup.json") }
    static var backups: URL { home.appendingPathComponent("backups", isDirectory: true) }
    static var markdown: URL { home.appendingPathComponent("toyl.md") }
    /// What toyl last wrote into toyl.md (its hash, and which save of toyl.json it was made
    /// from), so an edit made there by someone else can be told from toyl's own.
    static var markdownStamp: URL { home.appendingPathComponent(".toyl.md.stamp") }
    static var calendar: URL { home.appendingPathComponent("calendar.json") }
    static var agents: URL { home.appendingPathComponent("AGENTS.md") }

    /// Whether this is the real list, not a `TOYL_HOME` one (only the real one is linked into
    /// agents and found by Oyl).
    static var isReal: Bool { (ProcessInfo.processInfo.environment["TOYL_HOME"] ?? "").isEmpty }

    /// The installed app (what Claude and the command line are pointed at).
    static var installedApp: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/toyl.app")
    }

    /// The program to run for the command line and the MCP server: the installed app's, if
    /// there is one, else this one.
    static var program: URL {
        let installed = installedApp.appendingPathComponent("Contents/MacOS/toyl")
        if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        return Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    /// Where the `toyl` command goes: ~/.local/bin, which the shell already looks in.
    static var commandLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/toyl")
    }
}
