import Foundation

/// Decides which actions may run on their own. Reversible steps proceed.
/// Sending, posting, deleting, paying, and quitting stop unless this run was approved.
enum Policy {
    private static let consequentialLabels = ["send", "post", "delete", "trash", "purchase", "buy", "pay", "publish", "submit", "overwrite", "erase"]
    private static let consequentialGoals = consequentialLabels + ["reply", "comment", "order"]

    /// A reason to stop before the action, or nil when it may run.
    static func confirmationReason(operation: String, label: String, goal: String) -> String? {
        if operation == "QUIT_APP" {
            return "Quitting an application needs confirmation."
        }
        let haystack = "\(operation) \(label)".lowercased()
        if operation == "CLICK" || operation == "MENU" {
            if let word = consequentialLabels.first(where: { haystack.contains($0) }) {
                return "\"\(label)\" looks like a \(word) action and needs confirmation."
            }
        }
        if operation == "PRESS_RETURN" {
            let lowered = goal.lowercased()
            if let word = consequentialGoals.first(where: { lowered.contains($0) }) {
                return "Pressing Return would continue a \(word) action and needs confirmation."
            }
        }
        return nil
    }

    /// Empty allow lists mean every app is allowed. Names match the menu-bar name, ignoring Open/Quit prefixes.
    static func appAllowed(_ name: String, allow: [String]) -> Bool {
        if allow.isEmpty { return true }
        let normalized = normalize(name)
        guard !normalized.isEmpty else { return false }
        return allow.contains { item in
            let needle = normalize(item)
            guard !needle.isEmpty else { return false }
            if normalized == needle { return true }
            let nameWords = normalized.split(separator: " ").map(String.init)
            let needleWords = needle.split(separator: " ").map(String.init)
            return needleWords.allSatisfy { nameWords.contains($0) }
        }
    }

    static func browserName(in label: String) -> String? {
        guard let range = label.range(of: " in ", options: .caseInsensitive) else { return nil }
        let browser = label[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return browser.isEmpty ? nil : browser
    }

    /// Failures, or an empty list when the checks hold.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        expect(confirmationReason(operation: "QUIT_APP", label: "Quit Notes", goal: "quit notes") != nil, "quit should stop")
        expect(confirmationReason(operation: "CLICK", label: "Send", goal: "send the draft") != nil, "send should stop")
        expect(confirmationReason(operation: "CLICK", label: "Search", goal: "search solar eclipse") == nil, "search should run")
        expect(confirmationReason(operation: "PRESS_RETURN", label: "Press Return", goal: "search solar eclipse") == nil, "search return should run")
        expect(confirmationReason(operation: "PRESS_RETURN", label: "Press Return", goal: "send the email") != nil, "send return should stop")
        expect(confirmationReason(operation: "TYPE_TEXT", label: "Note body", goal: "type hello") == nil, "typing a draft should run")
        expect(appAllowed("Open Notes", allow: ["Notes"]), "Notes should match Open Notes")
        expect(!appAllowed("Cursor", allow: ["Notes"]), "Cursor should be outside a Notes allow list")
        expect(appAllowed("Google Chrome", allow: ["Chrome"]), "Chrome should match Google Chrome")
        expect(appAllowed("Finder", allow: []), "an empty allow list allows every app")
        expect(browserName(in: "Open wikipedia.org in Brave") == "Brave", "browser name should be readable")
        return failures
    }

    private static func normalize(_ name: String) -> String {
        var text = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["open ", "quit "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasSuffix(" folder") { text.removeLast(" folder".count) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
