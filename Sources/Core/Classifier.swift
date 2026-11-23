import Foundation

/// Autosort: which list a task belongs in, and which tags it wants, learned from where your
/// other tasks are (naive Bayes over their words, on the Mac, nothing sent anywhere). "pset 6"
/// goes where "pset 5" went. It only speaks up when it's fairly sure; Apple's on-device model
/// can weigh in on the rest (see `OnDevice`).
struct Classifier {
    private var docs: [String: Int] = [:]                 // list id → tasks
    private var counts: [String: [String: Int]] = [:]     // list id → word → count
    private var totals: [String: Int] = [:]               // list id → words
    private var tagDocs: [String: Int] = [:]              // tag (lowercased) → tasks
    private var tagCounts: [String: [String: Int]] = [:]  // tag → word → count
    private var tagTotals: [String: Int] = [:]
    private var tagNames: [String: String] = [:]          // lowercased → as written
    private var allCounts: [String: Int] = [:]
    private var allTotal = 0
    private var vocabulary = Set<String>()
    private var taskCount = 0

    /// Learns from every task in a list of yours (done ones too: they say just as much), and
    /// every tagged task.
    init(tasks: [TaskModel], lists: [ListModel]) {
        let usable = Set(lists.filter { !$0.isSpecial && !$0.archived }.map(\.id))
        for task in tasks {
            let words = Self.words(task.title + " " + task.notes.prefix(200))
            guard !words.isEmpty else { continue }
            vocabulary.formUnion(words)
            taskCount += 1
            for word in words { allCounts[word, default: 0] += 1 }
            allTotal += words.count
            if usable.contains(task.listId) {
                docs[task.listId, default: 0] += 1
                totals[task.listId, default: 0] += words.count
                for word in words { counts[task.listId, default: [:]][word, default: 0] += 1 }
            }
            for tag in task.tags {
                let key = tag.lowercased()
                tagNames[key] = tagNames[key] ?? tag
                tagDocs[key, default: 0] += 1
                tagTotals[key, default: 0] += words.count
                for word in words { tagCounts[key, default: [:]][word, default: 0] += 1 }
            }
        }
    }

    /// The list a task most likely belongs in, and how sure (0–1), if it's sure enough: at
    /// least two tasks there to go by, a word it knows, and better than even odds.
    func suggestList(for text: String, threshold: Double = 0.6) -> (id: String, confidence: Double)? {
        let words = Self.words(text).filter { vocabulary.contains($0) }
        let classes = docs.filter { $0.value >= 2 }
        guard !words.isEmpty, classes.count >= 1 else { return nil }
        // A softened prior (the square root of each list's size), so the biggest list doesn't win
        // whatever it's shown.
        let total = classes.values.reduce(0.0) { $0 + Double($1).squareRoot() }
        let size = Double(vocabulary.count)
        var scores: [(String, Double)] = []
        for (id, n) in classes {
            var score = log(Double(n).squareRoot() / total)
            let words_c = counts[id] ?? [:]
            let total_c = Double(totals[id] ?? 0)
            for word in words { score += log((Double(words_c[word] ?? 0) + 1) / (total_c + size)) }
            scores.append((id, score))
        }
        // One list alone: sure only if its words are this task's (else nothing to compare with).
        if scores.count == 1 {
            let id = scores[0].0
            let known = words.filter { (counts[id]?[$0] ?? 0) > 0 }.count
            return Double(known) / Double(words.count) >= 0.5 ? (id, 0.6) : nil
        }
        let top = scores.map(\.1).max()!
        let sum = scores.reduce(0) { $0 + exp($1.1 - top) }
        guard let best = scores.max(by: { $0.1 < $1.1 }) else { return nil }
        let confidence = exp(best.1 - top) / sum
        // And at least one of its words seen there.
        guard confidence >= threshold, words.contains(where: { (counts[best.0]?[$0] ?? 0) > 0 }) else { return nil }
        return (best.0, confidence)
    }

    /// Tags a task likely wants (as they're written elsewhere), the likeliest first.
    func suggestTags(for text: String, limit: Int = 3, threshold: Double = 0.7) -> [String] {
        let words = Self.words(text).filter { vocabulary.contains($0) }
        guard !words.isEmpty, taskCount > 0 else { return [] }
        let size = Double(vocabulary.count)
        var found: [(String, Double)] = []
        for (tag, n) in tagDocs where n >= 2 {
            let prior = Double(n) / Double(taskCount)
            var yes = log(prior), no = log(max(1 - prior, 0.01))
            let inTag = tagCounts[tag] ?? [:]
            let tagTotal = Double(tagTotals[tag] ?? 0)
            let restTotal = Double(allTotal) - tagTotal
            for word in words {
                let a = Double(inTag[word] ?? 0)
                yes += log((a + 1) / (tagTotal + size))
                no += log((Double(allCounts[word] ?? 0) - a + 1) / (max(restTotal, 0) + size))
            }
            let p = 1 / (1 + exp(no - yes))
            if p >= threshold, words.contains(where: { (inTag[$0] ?? 0) > 0 }) { found.append((tagNames[tag] ?? tag, p)) }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// A task's words, for learning: lowercased, accents dropped, numbers kept ("pset", "6"
    /// count; "the", "a", "to" don't).
    static func words(_ text: String) -> [String] {
        Query.fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "about", "this", "that", "these", "those", "then", "than",
        "to", "of", "in", "on", "at", "by", "an", "or", "is", "it", "be", "as", "do", "my", "me", "up", "so", "if",
        "get", "go", "out", "off", "over", "some", "all", "any", "more", "also", "just", "need", "needs", "should",
        "will", "can", "could", "would", "have", "has", "had", "are", "was", "were", "not", "no", "yes", "you", "your",
        // Everyday verbs and days, which say nothing about where a task belongs.
        "pick", "make", "take", "put", "set", "start", "finish", "check", "look", "find", "try", "add", "new", "due",
        "today", "tonight", "tomorrow", "week", "next", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "am", "pm",
    ]
}
