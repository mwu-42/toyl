import AppKit

/// One program, three ways: opened as an app, it's the window; run as `toyl <command>`, the
/// command line; run as `toyl mcp`, the MCP server.
@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "__snapshot" { exit(Picture.run(Array(arguments.dropFirst(2)))) }
        if arguments.count > 1, arguments[1] == "__phone" { exit(PhoneTry.run(Array(arguments.dropFirst(2)))) }
        if arguments.count > 1, arguments[1] == "__keys" { exit(KeysTry.run(Array(arguments.dropFirst(2)))) }
        if CLI.handles(arguments) { exit(CLI.run(arguments)) }
        ToylApp.run()
    }
}
