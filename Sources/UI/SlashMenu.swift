import SwiftUI

/// Where a field's slash menu is: which word's picked, and whether Escape put the menu away for
/// what's typed now (typing more brings it back).
struct SlashPick: Equatable {
    var index = 0
    var closedFor: String?
    /// The day weeks start on (for what "/nextfri" is).
    var weekStart = 1
    /// A title being changed: only days and what goes on a task.
    var editing = false

    /// The menu for what's typed, if one shows.
    func menu(_ text: String) -> (range: Range<String.Index>, words: [Quick.SlashWord])? {
        guard closedFor != text else { return nil }
        return Quick.slashMenu(text, weekStart: weekStart, editing: editing)
    }

    /// The picked word, kept within the menu.
    func picked(in count: Int) -> Int { min(max(index, 0), max(count - 1, 0)) }

    /// ↑ (-1) or ↓ (1), round from one end to the other. False with no menu showing.
    mutating func move(_ step: Int, in text: String) -> Bool {
        guard let menu = menu(text) else { return false }
        let count = menu.words.count
        index = (picked(in: count) + step + count) % count
        return true
    }

    /// Puts the picked word (or the one given) in place of what's half typed, with a space
    /// after it. False with no menu showing.
    mutating func take(_ choice: Int? = nil, in text: inout String) -> Bool {
        guard let menu = menu(text) else { return false }
        let word = menu.words[min(choice ?? picked(in: menu.words.count), menu.words.count - 1)]
        text.replaceSubrange(menu.range, with: "/" + word.word + " ")
        index = 0
        return true
    }

    /// What's typed changed: the first word picked again, and a menu Escape put away comes back
    /// (unless it's the same again).
    mutating func typed(_ text: String) {
        index = 0
        if closedFor != text { closedFor = nil }
    }

    /// Escape: the menu goes, what's typed stays. False with no menu showing.
    mutating func close(_ text: String) -> Bool {
        guard menu(text) != nil else { return false }
        closedFor = text
        return true
    }
}

/// The slash words a line could take, in a menu under its field, as "/" is typed: ↑ ↓ (or the
/// pointer) to pick, Return, Tab or a click to take one, Escape to put it away.
struct SlashMenu: View {
    let words: [Quick.SlashWord]
    let picked: Int
    let pick: (Int) -> Void
    let take: (Int) -> Void

    static let rowHeight: CGFloat = 28
    static let inset: CGFloat = 5
    /// The most words shown at once; ↑ ↓ go on to the rest (typing more narrows them).
    static let most = 8
    static let moreHeight: CGFloat = 22
    /// How tall it is with `count` words.
    static func height(_ count: Int) -> CGFloat {
        CGFloat(min(count, most)) * rowHeight + inset * 2 + (count > most ? moreHeight : 0)
    }
    /// The first word shown, so the picked one's in sight.
    static func first(picked: Int, count: Int) -> Int { max(0, min(picked - (most - 2), count - most)) }
    static let width: CGFloat = 340
    static func size(_ count: Int) -> CGSize { CGSize(width: width, height: height(count)) }

    var body: some View {
        let first = Self.first(picked: picked, count: words.count)
        let shown = Array(words.enumerated()).dropFirst(first).prefix(Self.most)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown), id: \.element) { index, word in
                HStack(spacing: 10) {
                    Text("/" + word.word).font(Theme.font(15)).foregroundStyle(Theme.ink)
                    Text(word.says).font(Theme.font(13)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if index == picked {
                        Image(systemName: "return").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.faint)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: Self.rowHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == picked ? Theme.selection : .clear))
                .contentShape(Rectangle())
                .onHover { inside in if inside { pick(index) } }
                .onTapGesture { take(index) }
            }
            if words.count > Self.most {
                Text("↑ ↓ for \(words.count - Self.most) more, or keep typing")
                    .font(Theme.font(12)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 10)
                    .frame(height: Self.moreHeight)
            }
        }
        .padding(Self.inset)
        .frame(width: Self.width, height: Self.height(words.count), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper).shadow(color: .black.opacity(0.13), radius: 14, y: 5))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.rule))
    }
}

/// What's in it, shown in a small window of its own over toyl's window, where this view is
/// laid out. So it takes clicks over the list it hangs over (an AppKit scroll view, which takes
/// clicks ahead of anything SwiftUI draws on it), and isn't cut off at the list's edge. The
/// window never takes the keys: typing stays in the field.
struct Floating<Content: View>: NSViewRepresentable {
    /// How big it is (said up front: its window can't be measured while toyl's is laid out).
    let size: CGSize
    let content: Content

    init(size: CGSize, @ViewBuilder _ content: () -> Content) {
        self.size = size
        self.content = content()
    }

    func makeNSView(context: Context) -> FloatingAnchor { FloatingAnchor() }

    func updateNSView(_ anchor: FloatingAnchor, context: Context) { anchor.show(AnyView(content)) }

    static func dismantleNSView(_ anchor: FloatingAnchor, coordinator: ()) { anchor.close() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView anchor: FloatingAnchor, context: Context) -> CGSize? { size }
}

/// Where a `Floating` is in its window, and the window that shows it there. Its window is
/// changed just after toyl's window is laid out, never during (SwiftUI doesn't allow it).
final class FloatingAnchor: NSView {
    /// Room around it for its shadow.
    private static let margin: CGFloat = 24
    private var hosting: NSHostingView<AnyView>?
    private var content: AnyView?
    private let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var scrolling: NSObjectProtocol?
    private var waiting = false
    private var closed = false

    init() {
        super.init(frame: .zero)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
    }

    required init?(coder: NSCoder) { nil }

    func show(_ content: AnyView) {
        self.content = content
        soon()
    }

    func close() {
        closed = true
        if let scrolling { NotificationCenter.default.removeObserver(scrolling) }
        scrolling = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return close() }
        closed = false
        // Inside a scroll view (the + line in the list): it follows the scrolling.
        if scrolling == nil, let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrolling = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.soon() }
            }
        }
        soon()
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        soon()
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        soon()
    }

    /// Once toyl's window is done laying out.
    private func soon() {
        guard !waiting else { return }
        waiting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            waiting = false
            place()
        }
    }

    /// Its window over this spot, showing what's in it; put away if the spot's out of sight.
    private func place() {
        guard !closed, let window, let content else { return }
        if let scroll = enclosingScrollView, !scroll.bounds.intersects(convert(bounds, to: scroll)) {
            panel.orderOut(nil)
            return
        }
        let shown = AnyView(content.padding(Self.margin))
        if let hosting { hosting.rootView = shown } else {
            let made = NSHostingView(rootView: shown)
            panel.contentView = made
            hosting = made
        }
        let spot = window.convertToScreen(convert(bounds, to: nil)).insetBy(dx: -Self.margin, dy: -Self.margin)
        if panel.frame != spot { panel.setFrame(spot, display: true) }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible, window.isVisible { panel.orderFront(nil) }
    }
}

/// A window that shows something and takes clicks, but never the keys.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
