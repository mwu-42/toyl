import AppKit
import SwiftUI

/// toyl's look: Apple Notes' quiet, on near-white paper with the faintest warmth, everything in
/// Times New Roman and in lower case, italics hardly ever. Its one color of its own is a gray-gold,
/// for what's done and what's now; a muted red says late; each list keeps its color (or emoji).
enum Theme {
    static let paper = Color(nsColor: nsPaper)
    static let sidebar = Color(nsColor: nsSidebar)
    static let ink = Color(nsColor: nsInk)
    static let secondary = Color(nsColor: nsSecondary)
    static let faint = Color(nsColor: nsFaint)
    static let rule = Color(red: 0.902, green: 0.902, blue: 0.890)              // #e6e6e3
    static let selection = Color(red: 0.918, green: 0.918, blue: 0.906)         // #eaeae7
    static let selectionFocused = Color(red: 0.878, green: 0.875, blue: 0.859)  // #e0dfdb
    static let hover = Color(red: 0.949, green: 0.949, blue: 0.941)             // #f2f2f0
    static let accent = Color(red: 0.592, green: 0.553, blue: 0.475)            // #978d79, a gray-gold
    static let late = Color(red: 0.659, green: 0.353, blue: 0.314)              // #a85a50
    static let field = Color(red: 0.937, green: 0.937, blue: 0.929)             // #efefed

    static let nsPaper = NSColor(srgbRed: 0.984, green: 0.984, blue: 0.980, alpha: 1)    // #fbfbfa
    static let nsSidebar = NSColor(srgbRed: 0.957, green: 0.957, blue: 0.949, alpha: 1)  // #f4f4f2
    static let nsInk = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.110, alpha: 1)
    static let nsSecondary = NSColor(srgbRed: 0.451, green: 0.451, blue: 0.439, alpha: 1)
    static let nsFaint = NSColor(srgbRed: 0.651, green: 0.651, blue: 0.635, alpha: 1)

    static let face = "Times New Roman"

    static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> Font {
        var font = Font.custom(face, size: size)
        if bold { font = font.weight(.bold) }
        if italic { font = font.italic() }
        return font
    }

    static func nsFont(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let base = NSFont(name: face, size: size) ?? NSFont.systemFont(ofSize: size)
        return traits.isEmpty ? base : NSFontManager.shared.font(withFamily: face, traits: traits, weight: bold ? 9 : 5, size: size) ?? base
    }

    static let body = font(16)
    static let small = font(13.5)
    static let meta = font(13.5)
    static let heading = font(13.5)
    static let title = font(30, bold: true)
    static let sidebarItem = font(15.5)

    static func color(hex: String) -> Color {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0x8c8c8c
        return Color(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
}

/// A field with nothing round it (no bezel, no focus ring), in the theme's face, that says when
/// Return, Escape, Tab and the arrows are pressed. SwiftUI's own field can't be styled this
/// plainly, or hand those keys over.
///
/// The caret: `autofocus` takes it when the field appears (at the end of what's there, or with it
/// all selected); `focus` takes it again each time the number changes. A `name` lets the window
/// find the field (Return and typing in the list go to the one named "quick"). Escape, unless
/// asked for, just lets go of the keys.
struct PlainField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var font = Theme.nsFont(16)
    var color = Theme.nsInk
    var name: String?
    var autofocus = false
    var selectAll = false
    /// Changed to put the caret here.
    var focus = 0
    var onSubmit: (() -> Void)?
    /// ⌘Return (else it's Return).
    var onCommandSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onTab: (() -> Bool)?
    var onBackTab: (() -> Bool)?
    var onUp: (() -> Bool)?
    var onDown: (() -> Bool)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = InkField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: field)
        field.stringValue = text
        field.name = name
        field.selectsAllOnFocus = selectAll
        field.focusOnAppear = autofocus
        field.onCommandReturn = onCommandSubmit ?? onSubmit
        context.coordinator.focus = focus
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        apply(to: field)
        // Only what's been changed from outside (cleared after adding, a tab finished): never while
        // letters are being put together (an accent held, a Japanese word), which it would undo.
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
        }
        if let ink = field as? InkField {
            if ink.name != name { ink.name = name }
            ink.onCommandReturn = onCommandSubmit ?? onSubmit
        }
        if focus != context.coordinator.focus {
            context.coordinator.focus = focus
            DispatchQueue.main.async { (field as? InkField)?.takeKeys() }
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil
    }

    private func apply(to field: NSTextField) {
        if field.font != font { field.font = font }
        if field.textColor != color { field.textColor = color }
        let shown = NSAttributedString(string: placeholder, attributes: [.font: Theme.nsFont(font.pointSize), .foregroundColor: Theme.nsFaint])
        if field.placeholderAttributedString?.string != placeholder { field.placeholderAttributedString = shown }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlainField
        var focus = 0

        init(_ parent: PlainField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func controlTextDidEndEditing(_ notification: Notification) { parent.onEnd?() }

        /// The caret in ink, not the system's blue.
        func controlTextDidBeginEditing(_ notification: Notification) {
            ((notification.object as? NSTextField)?.currentEditor() as? NSTextView)?.insertionPointColor = Theme.nsInk
            parent.onBegin?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                guard let submit = parent.onSubmit else { return false }
                submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if let escape = parent.onEscape { escape() } else { control.window?.makeFirstResponder(nil) }
                return true
            case #selector(NSResponder.insertTab(_:)): return parent.onTab?() ?? false
            case #selector(NSResponder.insertBacktab(_:)): return parent.onBackTab?() ?? false
            case #selector(NSResponder.moveUp(_:)): return parent.onUp?() ?? false
            case #selector(NSResponder.moveDown(_:)): return parent.onDown?() ?? false
            default: return false
            }
        }
    }
}

/// A text field whose caret is ink, not the system's blue, that can take the keys as soon as it's
/// on screen, and can be found by its name.
final class InkField: NSTextField {
    var name: String? {
        didSet {
            guard name != oldValue else { return }
            if let oldValue, Self.fields[oldValue]?.field === self { Self.fields[oldValue] = nil }
            if let name, window != nil { Self.fields[name] = Weak(field: self) }
        }
    }
    /// Take the keys when it first shows.
    var focusOnAppear = false
    /// What ⌘Return does while it has the keys (a key equivalent, so it's caught here, before
    /// the menus and before the text sees it).
    var onCommandReturn: (() -> Void)?
    /// Taking the keys selects everything in it (renaming), rather than going to its end.
    var selectsAllOnFocus = false

    private struct Weak { weak var field: InkField? }
    private static var fields: [String: Weak] = [:]

    /// The field with this name that's on screen, if there is one.
    static func named(_ name: String) -> InkField? {
        guard let field = fields[name]?.field, field.window != nil else { return nil }
        return field
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let name {
            if window != nil { Self.fields[name] = Weak(field: self) }
            else if Self.fields[name]?.field === self { Self.fields[name] = nil }
        }
        guard window != nil, focusOnAppear else { return }
        focusOnAppear = false
        DispatchQueue.main.async { [weak self] in self?.takeKeys() }
    }

    /// Has the keys now (the caret at the end, or everything selected).
    var hasKeys: Bool {
        guard let editor = currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// Takes the keys: the caret at the end of what's there (or all of it selected).
    func takeKeys() {
        guard let window else { return }
        if !hasKeys { window.makeFirstResponder(self) }
        guard let editor = currentEditor() else { return }
        let length = (stringValue as NSString).length
        editor.selectedRange = selectsAllOnFocus ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if hasKeys, [36, 76].contains(event.keyCode), event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let submit = onCommandReturn {
            submit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        (currentEditor() as? NSTextView)?.insertionPointColor = Theme.nsInk
        return became
    }
}

/// Who has the keys in toyl's window.
@MainActor
enum Keys {
    /// toyl's main window (set when its keys are watched).
    static weak var window: NSWindow?

    /// The field that has the keys lets go of them, so the list has them.
    static func letGo() {
        guard let window = window ?? NSApp.keyWindow, window.firstResponder is NSText else { return }
        window.makeFirstResponder(nil)
    }
}

/// A task's box: a ring, gold and ticked once it's done (as Notes' checklists are). Late doesn't
/// change it: late is said quietly, on the date alone.
struct CheckCircle: View {
    let done: Bool
    var late = false
    var size: CGFloat = 17

    var body: some View {
        ZStack {
            Circle().strokeBorder(Theme.faint, lineWidth: 1.2).opacity(done ? 0 : 1)
            if done {
                Circle().fill(Theme.accent).transition(.scale(scale: 0.3).combined(with: .opacity))
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
                    .transition(.scale(scale: 0.2, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(done ? 1 : 0.96)
        .animation(.spring(response: 0.24, dampingFraction: 0.5), value: done)
        .contentShape(Circle())
    }
}

/// A countdown's ring, emptying as it goes.
struct Ring: View {
    let fraction: Double
    var size: CGFloat = 14
    var line: CGFloat = 2
    var color = Theme.accent

    var body: some View {
        ZStack {
            Circle().stroke(Theme.rule, lineWidth: line)
            Circle().trim(from: 0, to: max(min(fraction, 1), 0))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// A word or two on a soft ground: what quick add read, a tag.
struct Chip: View {
    let text: String
    var tint = Theme.secondary
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.font(12.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(filled ? tint.opacity(0.12) : Theme.field))
    }
}

/// A plain button: words (or a symbol) that darken when pointed at.
struct Quiet: View {
    let label: String
    var symbol: String?
    var size: CGFloat = 13.5
    var tint = Theme.secondary
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: size - 2)) }
                if !label.isEmpty { Text(label).font(Theme.font(size)) }
            }
            .foregroundStyle(hovering ? Theme.ink : tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A thin rule across.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.rule).frame(height: 1) }
}

extension View {
    /// The theme's face at a size, set on everything inside.
    func times(_ size: CGFloat = 16, italic: Bool = false) -> some View { font(Theme.font(size, italic: italic)) }
}

/// SwiftUI's `@State`, by its type: in the macOS 26 SDK the attribute is a macro whose plugin
/// only ships with Xcode, and toyl's built with the command line tools alone (as Oyl is).
typealias Local<Value> = SwiftUI.State<Value>
