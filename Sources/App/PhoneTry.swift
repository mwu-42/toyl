import AppKit
import WebKit

/// `toyl __phone <seconds> [picture.png]`: the iPhone page served for a while on localhost:47659
/// with the code 123456 (only with a `TOYL_HOME` list), for trying it with curl; and, given a
/// file, drawn at an iPhone's size after pairing, offscreen. Nothing shows on screen.
enum PhoneTry {
    static let port: UInt16 = 47659
    static let code = "123456"

    static func run(_ arguments: [String]) -> Int32 {
        guard !Paths.isReal, let seconds = arguments.first.flatMap(Double.init) else {
            FileHandle.standardError.write(Data("toyl: __phone needs TOYL_HOME and how many seconds\n".utf8))
            return 2
        }
        return MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            NSApp.appearance = NSAppearance(named: .aqua)
            AppModel.phoneTesting = (code, port)
            let store = Store()
            let timers = TimerEngine(store: store)
            let calendar = CalendarBridge(store: store)
            let model = AppModel(store: store, timers: timers, calendar: calendar)
            print("serving http://localhost:\(port) · code \(code)")
            fflush(stdout)
            var keep: [AnyObject] = [model]
            if arguments.count > 1 {
                let file = URL(fileURLWithPath: arguments[1])
                let size = NSSize(width: 393, height: 852)
                let web = WKWebView(frame: NSRect(origin: .zero, size: size))
                web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1"
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = web
                keep += [web, window]
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                web.load(URLRequest(url: URL(string: "http://localhost:\(port)/pair?code=\(code)")!))
                RunLoop.main.run(until: Date().addingTimeInterval(3.5))
                var drawn = false
                web.takeSnapshot(with: nil) { image, _ in
                    if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: file)
                        print("drew \(file.path)")
                    }
                    drawn = true
                }
                let until = Date().addingTimeInterval(5)
                while !drawn, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            _ = keep
            return 0
        }
    }
}
