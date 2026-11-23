import AppKit
import LinkPresentation
import SwiftUI

/// Links in a task's notes (or an event's description), shown as cards: the page's icon and
/// title, where it is, and a click to open it.
enum NoteLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The web links in some text, in order, each once.
    static func links(in text: String) -> [URL] {
        guard let detector, !text.isEmpty else { return [] }
        var seen = Set<URL>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> URL? in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !seen.contains(url) else { return nil }
            seen.insert(url)
            return url
        }
    }

    /// The text with its web links taken out (they show as cards), blank lines closed up.
    static func withoutLinks(_ text: String) -> String {
        guard let detector, !text.isEmpty else { return text }
        var out = text
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let range = Range(match.range, in: out) else { continue }
            out.removeSubrange(range)
        }
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .split(whereSeparator: \.isEmpty)
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    /// "nytimes.com/2026/11/…": where it is, short.
    static func place(_ url: URL) -> String {
        var host = url.host() ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return host }
        return host + "/" + (path.count > 28 ? String(path.prefix(28)) + "…" : path)
    }
}

/// Page titles and icons, fetched once a session (by Apple's LinkPresentation, as Notes and
/// Messages do).
@MainActor
final class LinkPreviews: ObservableObject {
    static let shared = LinkPreviews()

    struct Preview: Equatable {
        var title: String?
        var icon: NSImage?
    }

    @Published private(set) var previews: [URL: Preview] = [:]
    private var fetching: [URL: LPMetadataProvider] = [:]

    func load(_ url: URL) {
        guard previews[url] == nil, fetching[url] == nil else { return }
        let provider = LPMetadataProvider()
        provider.timeout = 12
        fetching[url] = provider
        provider.startFetchingMetadata(for: url) { metadata, _ in
            let title = metadata?.title
            let iconProvider = metadata?.iconProvider
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let shared = LinkPreviews.shared
                    shared.fetching[url] = nil
                    shared.previews[url] = Preview(title: title?.trimmingCharacters(in: .whitespacesAndNewlines), icon: nil)
                }
            }
            iconProvider?.loadObject(ofClass: NSImage.self) { image, _ in
                guard let image = image as? NSImage else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { LinkPreviews.shared.previews[url]?.icon = image }
                }
            }
        }
    }
}

/// A link as a card: icon, title, where it is. Click to open it.
struct LinkCard: View {
    let url: URL
    var compact = false
    @ObservedObject private var previews = LinkPreviews.shared
    @Local private var hovering = false

    var body: some View {
        let preview = previews.previews[url]
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: compact ? 6 : 10) {
                LinkIcon(image: preview?.icon, size: compact ? 13 : 20)
                if compact {
                    Text(title(preview)).font(Theme.font(13)).foregroundStyle(Theme.secondary).lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(preview)).font(Theme.font(14.5)).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(NoteLinks.place(url)).font(Theme.font(12)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 2 : 8)
            .background(RoundedRectangle(cornerRadius: compact ? 6 : 9).fill(hovering ? Theme.selectionFocused : Theme.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: url) { previews.load(url) }
        .contextMenu {
            Button("open") { NSWorkspace.shared.open(url) }
            Button("copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        .help(url.absoluteString)
    }

    /// The page's title in lower case (toyl's way), else where it is.
    private func title(_ preview: LinkPreviews.Preview?) -> String {
        guard let title = preview?.title, !title.isEmpty else { return NoteLinks.place(url) }
        return title.lowercased()
    }
}

/// A page's icon, or a globe until it's known.
private struct LinkIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.7)).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

/// Notes as they read: the words (links taken out), then a card for each link. Click the words
/// to change them.
struct RenderedNotes: View {
    let text: String
    var edit: (() -> Void)?

    var body: some View {
        let words = NoteLinks.withoutLinks(text)
        VStack(alignment: .leading, spacing: 6) {
            if !words.isEmpty {
                Text(words)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { edit?() }
            }
            ForEach(NoteLinks.links(in: text), id: \.self) { url in LinkCard(url: url) }
        }
    }
}
