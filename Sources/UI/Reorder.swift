import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What can be dragged in toyl, as the text it's carried as.
/// - tasks `toyl:id,id` · an event `toyl-event:calendar|id` · a panel `toyl-panel:name`
/// - a list `toyl-list:id` · a group `toyl-group:id` · a filter `toyl-filter:id` · a place `toyl-place:key`
/// - a project `toyl-project:list|id` · a sublist item `toyl-sub:task|item`
enum Drag {
    static func kind(_ payload: String?) -> String {
        guard let payload else { return "text" }
        if payload.hasPrefix("toyl:") { return "tasks" }
        guard payload.hasPrefix("toyl-"), let colon = payload.firstIndex(of: ":") else { return "text" }
        return String(payload[payload.index(payload.startIndex, offsetBy: 5)..<colon])
    }

    /// What follows the kind ("toyl-list:abc" → "abc").
    static func value(_ payload: String) -> String {
        guard let colon = payload.firstIndex(of: ":") else { return payload }
        return String(payload[payload.index(after: colon)...])
    }

    /// The two halves of "a|b".
    static func pair(_ payload: String) -> (String, String)? {
        let parts = value(payload).split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
}

extension View {
    /// Draggable as `payload`, the window told what's being dragged (so what it passes over can
    /// show where it'd go: a line between, or a place lit up to drop into).
    func toylDrag<Preview: View>(_ model: AppModel, _ payload: String, @ViewBuilder preview: @escaping () -> Preview) -> some View {
        toylDrag(model, { payload }, preview: preview)
    }

    /// The same, with what's dragged worked out only when a drag starts (a selection's ids, say).
    func toylDrag<Preview: View>(_ model: AppModel, _ payload: @escaping () -> String, @ViewBuilder preview: @escaping () -> Preview) -> some View {
        onDrag {
            let made = payload()
            model.dragging = made
            return NSItemProvider(object: made as NSString)
        } preview: {
            preview()
        }
    }

    /// A drop target in a column of things. What `reorders` says yes to goes above or below this
    /// one, by the half the pointer's in, with a line where it'd go; anything else it `accepts`
    /// is dropped into it, and `lit` is on while it's over.
    func columnDrop(_ model: AppModel, lit: Binding<Bool>? = nil, inset: CGFloat = 6,
                    accepts: @escaping (String) -> Bool = { _ in true },
                    reorders: @escaping (String) -> Bool,
                    drop: @escaping (_ items: [String], _ spot: RowSpot) -> Bool) -> some View {
        modifier(ColumnDrop(model: model, lit: lit, inset: inset, accepts: accepts, reorders: reorders, drop: drop))
    }
}

/// Where something dropped on a row goes.
enum RowSpot: Equatable { case above, below, into }

private struct ColumnDrop: ViewModifier {
    let model: AppModel
    let lit: Binding<Bool>?
    let inset: CGFloat
    let accepts: (String) -> Bool
    let reorders: (String) -> Bool
    let drop: ([String], RowSpot) -> Bool
    @Local private var height: CGFloat = 0
    @Local private var spot: RowSpot?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: spot == .below ? .bottom : .top) {
                if spot == .above || spot == .below {
                    Rectangle().fill(Theme.accent).frame(height: 2)
                        .padding(.horizontal, inset)
                        .offset(y: spot == .above ? -1 : 1)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.plainText], delegate: Delegate(model: model, height: height, accepts: accepts, reorders: reorders,
                                                         drop: drop, spot: $spot, lit: lit))
    }

    struct Delegate: DropDelegate {
        let model: AppModel
        let height: CGFloat
        let accepts: (String) -> Bool
        let reorders: (String) -> Bool
        let drop: ([String], RowSpot) -> Bool
        @Binding var spot: RowSpot?
        let lit: Binding<Bool>?

        private func edge(_ info: DropInfo) -> RowSpot { info.location.y < height / 2 ? .above : .below }

        /// Not one it takes: it steps aside, so what's around it can take it (a task over a
        /// sublist item goes to the task's row).
        /// What's being dragged now: from the drag itself (so one cancelled earlier, or dropped
        /// somewhere else, can't be mistaken for it), else what toyl last started dragging.
        private var dragging: String {
            NSPasteboard(name: .drag).string(forType: .string) ?? model.dragging ?? ""
        }

        func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) && accepts(dragging) }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            let dragging = self.dragging
            guard accepts(dragging) else {
                spot = nil
                lit?.wrappedValue = false
                return DropProposal(operation: .forbidden)
            }
            spot = reorders(dragging) ? edge(info) : .into
            lit?.wrappedValue = spot == .into
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            spot = nil
            lit?.wrappedValue = false
        }

        func performDrop(info: DropInfo) -> Bool {
            let at = edge(info)
            spot = nil
            lit?.wrappedValue = false
            let providers = info.itemProviders(for: [.plainText])
            guard !providers.isEmpty else { return false }
            let model = model, reorders = reorders, accepts = accepts, drop = drop
            let collected = Collected()
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    if let text = object as? NSString { collected.add(text as String) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                MainActor.assumeIsolated {
                    model.dragging = nil
                    let items = collected.items
                    // What's really dropped decides (what the window thought was being dragged may be old).
                    guard let first = items.first, accepts(first) else { return }
                    _ = drop(items, reorders(first) ? at : .into)
                }
            }
            return true
        }
    }

    /// Items from the drag, gathered as they load.
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ item: String) { lock.lock(); list.append(item); lock.unlock() }
        var items: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }
}

/// Telling a double-click from two single ones, for rows whose first click already does something
/// (selects, opens): the second click on the same thing, soon enough, is the double.
@MainActor
enum DoubleClick {
    private static var last: (key: String, at: Date)?

    /// Whether this click on `key` is the second of a double-click.
    static func second(_ key: String) -> Bool {
        let now = Date()
        if let last, last.key == key, now.timeIntervalSince(last.at) < NSEvent.doubleClickInterval {
            Self.last = nil
            return true
        }
        last = (key, now)
        return false
    }
}
