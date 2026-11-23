import AppKit
import SwiftUI

/// `toyl __snapshot <place> <file.png> [form|settings|completing|select:<id>|calendar|calendar:<day>]`: draws the window (or the add-to-calendar form) into a
/// picture without showing anything on screen: no Dock icon, no window, nothing brought forward.
/// For checking how toyl looks while it's being worked on (only with a `TOYL_HOME` list).
enum Picture {
    static func run(_ arguments: [String]) -> Int32 {
        guard !Paths.isReal, arguments.count >= 2 else {
            FileHandle.standardError.write(Data("toyl: __snapshot needs TOYL_HOME, a place and a file\n".utf8))
            return 2
        }
        return MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            NSApp.appearance = NSAppearance(named: .aqua)
            let store = Store()
            let timers = TimerEngine(store: store)
            let calendar = CalendarBridge(store: store)
            let model = AppModel(store: store, timers: timers, calendar: calendar)
            model.place = Place(key: arguments[0]) ?? .today
            if arguments.count >= 3, arguments[2].hasPrefix("select:") { model.selection = [String(arguments[2].dropFirst(7))] }
            let mode = arguments.count >= 3 ? arguments[2] : ""
            if mode.hasPrefix("calendar") {
                model.showCalendar = true
                if mode.hasPrefix("calendar:") { model.calendarDay = String(mode.dropFirst(9)) }
            }
            let size = mode == "form" ? NSSize(width: 540, height: 640) : mode == "settings" ? NSSize(width: 620, height: 1400)
                : mode.hasPrefix("calendar") ? NSSize(width: 1480, height: 820) : NSSize(width: 1180, height: 760)
            let root: AnyView
            if mode == "settings" {
                root = AnyView(SettingsView(model: model, calendar: calendar))
            } else if mode == "completing", let first = model.visible.first {
                model.completing = [first.id]
                root = AnyView(RootView(model: model))
            } else if arguments.count >= 3, arguments[2] == "form" {
                var form = EventForm()
                form.title = "Tic Letter #2 — Due"
                form.day = "mon"
                form.allDay = true
                form.reason = "nothing says where it goes"
                root = AnyView(AddToCalendarView(model: model, form: form))
            } else {
                root = AnyView(RootView(model: model))
            }
            let view = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
            view.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = view
            window.backgroundColor = Theme.nsPaper
            RunLoop.main.run(until: Date().addingTimeInterval(mode.hasPrefix("calendar") || mode.hasPrefix("select:") ? 4 : 1.2))
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
            view.cacheDisplay(in: view.bounds, to: picture)
            guard let png = picture.representation(using: .png, properties: [:]) else { return 1 }
            do { try png.write(to: URL(fileURLWithPath: arguments[1])) } catch { return 1 }
            print("drew \(arguments[1])")
            return 0
        }
    }
}
