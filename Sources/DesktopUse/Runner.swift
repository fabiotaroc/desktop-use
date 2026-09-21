import AppKit
import Foundation
import JevCore

struct ActionRecord: Encodable {
    var operation: String
    var target: String
    var result: String
}

struct PendingAction: Encodable {
    var operation: String
    var target: String
    var reason: String
}

struct RunReport: Encodable {
    var status: String
    var summary: String
    var application: String
    var window: String
    var actions: [ActionRecord]
    var pending: PendingAction?
    var decisionSeconds: Double

    var exitCode: Int32 {
        switch status {
        case "done":
            return 0
        case "needs_confirmation", "unclear":
            return 2
        case "blocked":
            return 3
        default:
            return summary.localizedCaseInsensitiveContains("accessibility") ? 4 : 1
        }
    }
}

/// One observe → decide → act loop. The cycle is adapted from jev-use: Jev picks a typed
/// operation, and this process performs it. The accessibility tree stays inside the loop.
@MainActor
struct Session {
    let goal: String
    let allow: [String]
    let approve: Bool
    let maxSteps: Int
    let verbose: Bool
    let apiKey: String
    private let trace = Trace()

    private final class Trace {
        var actions: [ActionRecord] = []
        var application = ""
        var window = ""
        var decisionSeconds = 0.0
    }

    private struct ChainStep {
        let operation: String
        let label: String
        let role: String?
        let place: String?
        let ordinal: Int
        let text: String?
        let action: DesktopAction?
        var effective: Bool
    }

    func run() async -> RunReport {
        guard let first = NSWorkspace.shared.frontmostApplication, Desktop.isControllable(first) else {
            return report(status: "error", summary: "No controllable app is in front. Switch to the app this task should start from.", actions: [], pending: nil, seconds: 0)
        }
        do {
            return try await cycles(starting: first)
        } catch is CancellationError {
            return report(status: "blocked", summary: "Cancelled.", application: name(first), actions: [], pending: nil, seconds: 0)
        } catch {
            let summary = trace.actions.isEmpty ? error.localizedDescription : "\(error.localizedDescription) Stopped after \(trace.actions.count) completed action\(trace.actions.count == 1 ? "" : "s")."
            return report(status: "error", summary: summary, application: trace.application.isEmpty ? name(first) : trace.application, window: trace.window, actions: trace.actions, pending: nil, seconds: trace.decisionSeconds)
        }
    }

    private func cycles(starting first: NSRunningApplication) async throws -> RunReport {
        var app = first
        let input = CommandInput(goal)
        var recent: [JevClient.RecentAction] = []
        var noChange = 0
        var lastResult = "Done"
        var ineffective = Set<String>()
        var lastPick = ""
        var samePick = 0
        let noEffect = "no visible effect"
        var count = input.count
        var lastOffered = Set<String>()
        var lastClicked = Set<String>()
        var unreadable = 0
        var navigated = false
        var windowChanged = false
        var decisionSeconds = 0.0
        let goalWords = Set(goal.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        var chain: [ChainStep] = []
        var chainWindow: AXUIElement?
        var everyWindow = 0.0
        let limit = max(1, maxSteps)

        func halted(_ status: String, _ summary: String, pending: PendingAction? = nil, sure: Bool = true) async throws -> RunReport {
            var summary = summary
            if status == "done" {
                chain = chain.filter(\.effective)
                if everyWindow >= 0.6, sure, !chain.isEmpty {
                    summary = try await replay(chain, in: app, except: chainWindow)
                } else if everyWindow >= 0.6, !sure {
                    summary += " Not repeated in the other windows."
                }
            }
            trace.application = name(app)
            trace.decisionSeconds = decisionSeconds
            return report(status: status, summary: summary, application: name(app), window: Desktop.describe(app).title, actions: trace.actions, pending: pending, seconds: decisionSeconds)
        }

        for cycle in 1...limit {
            try Task.checkCancellation()
            if app.isTerminated {
                guard let next = Desktop.currentTarget(fallback: nil) else {
                    return report(status: "blocked", summary: "The app quit and nothing controllable is in front.", application: name(app), actions: trace.actions, pending: nil, seconds: decisionSeconds)
                }
                app = next
            }
            note("cycle \(cycle): reading \(name(app))")
            var snapshot = try await Desktop.capture(application: app, command: goal)
            func pageControls(_ snapshot: DesktopSnapshot) -> Int {
                snapshot.candidates(of: [.control, .focus]).filter { snapshot.meta[$0.id]?.place == "page" }.count
            }
            func offeredIDs(_ snapshot: DesktopSnapshot) -> Set<String> {
                Set(snapshot.candidates(of: [.control, .focus]).map(\.id))
            }
            if windowChanged, snapshot.usesWebContent {
                for _ in 0..<5 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    let next = try await Desktop.capture(application: app, command: goal)
                    let same = offeredIDs(next) == offeredIDs(snapshot)
                    snapshot = next
                    if same { break }
                }
            }
            windowChanged = false
            for _ in 0..<8 where navigated && Desktop.isBrowser(app) && (pageControls(snapshot) < 5 || offeredIDs(snapshot) == lastOffered) {
                note("cycle \(cycle): waiting for the page")
                try await Task.sleep(nanoseconds: 400_000_000)
                snapshot = try await Desktop.capture(application: app, command: goal)
            }
            navigated = false
            let offered = offeredIDs(snapshot)
            if let last = recent.last, last.result.hasSuffix(noEffect), offered != lastOffered {
                recent[recent.count - 1] = JevClient.RecentAction(action: last.action, result: last.result.replacingOccurrences(of: noEffect, with: "the window's content changed"), screenChanged: false)
                noChange = 0
                ineffective.subtract(lastClicked)
                if !chain.isEmpty { chain[chain.count - 1].effective = true }
            }
            lastOffered = offered

            let built = offer(snapshot: snapshot, goalWords: goalWords, ineffective: ineffective)
            let windowCount = Desktop.windows(of: app).count
            let state = JevClient.CycleState(
                goal: goal, dictation: nil, application: name(app), window: snapshot.windowTitle,
                elements: built.elements, available: built.available, recentActions: Array(recent.suffix(10)),
                previous: nil, count: count, otherWindows: windowCount > 1 ? windowCount - 1 : nil)
            let began = Date()
            let decision = try await JevClient.cycle(state: state, operations: built.operations, heads: built.heads, apiKey: apiKey)
            decisionSeconds += Date().timeIntervalSince(began)
            trace.decisionSeconds = decisionSeconds
            trace.application = name(app)
            guard var operation = decision.choice("operation") else { throw DecisionError.invalidResponse }

            var substituted = false
            var inputMissing = false
            if operation.id == "TYPE_TEXT", decision.choice("type_target")?.id == "none",
               let next = (decision.answers["operation"]?.probabilities ?? [:]).filter({ ["MENU", "CLICK"].contains($0.key) }).max(by: { $0.value < $1.value }) {
                substituted = true
                inputMissing = true
                note("cycle \(cycle): wanted input is not offered; using \(next.key)")
                operation = (next.key, next.value, operation.confidence)
            }
            if operation.id == "TYPE_TEXT", let create = decision.answers["create_first"]?.noul, create >= 0.5,
               let next = (decision.answers["operation"]?.probabilities ?? [:]).filter({ ["MENU", "CLICK"].contains($0.key) }).max(by: { $0.value < $1.value }) {
                substituted = true
                note("cycle \(cycle): create something new before typing; using \(next.key)")
                operation = (next.key, next.value, operation.confidence)
            }
            if decision.answers["every_window"] != nil { everyWindow = decision.noul("every_window") }
            let headName = ["CLICK": "click_target", "TYPE_TEXT": "type_target", "OPEN_APP": "app_target", "OPEN_URL": "url_target",
                            "OPEN_FOLDER": "folder_target", "MENU": "menu_target", "QUIT_APP": "quit_target", "ARRANGE_WINDOWS": "arrange_target"][operation.id]
            var target = headName.flatMap { decision.choice($0) }
            if inputMissing, operation.id == "CLICK",
               let best = (decision.answers["click_target"]?.probabilities ?? [:]).filter({ entry in !built.inputs.contains { $0.id == entry.key } }).max(by: { $0.value < $1.value }) {
                target = (best.key, best.value, target?.confidence ?? best.value)
            }
            let targetCandidate = target.flatMap { chosen in snapshot.candidates.first { $0.id == chosen.id } }
            note("cycle \(cycle): \(operation.id) \(Int(operation.probability * 100))% \(targetCandidate?.label ?? "")")

            if ["DONE", "BLOCKED"].contains(operation.id), snapshot.usesWebContent, !snapshot.webContentReady, snapshot.window != nil, unreadable < 2 {
                unreadable += 1
                note("cycle \(cycle): ignored \(operation.id) on an unreadable page")
                try await Task.sleep(nanoseconds: 400_000_000)
                continue
            }
            switch operation.id {
            case "DONE":
                let summary = recent.isEmpty ? "Already done. Nothing to do for: \(goal)" : lastResult
                return try await halted("done", summary, sure: operation.probability >= 0.6)
            case "BLOCKED":
                let summary = recent.isEmpty ? "Nothing on screen in \(name(app)) can do: \(goal)" : "Stopped after \(trace.actions.count) actions. Nothing on screen can continue. Last: \(lastResult)"
                return try await halted("blocked", summary)
            case "WAIT":
                try await Task.sleep(nanoseconds: 400_000_000)
                recent.append(JevClient.RecentAction(action: "WAIT", result: "waited 0.4s", screenChanged: false))
                continue
            default:
                break
            }
            if headName != nil && targetCandidate == nil {
                recent.append(JevClient.RecentAction(action: operation.id, result: "no target offered", screenChanged: false))
                noChange += 1
                if noChange >= 3 {
                    return try await halted("blocked", "No target for \(operation.id) in \(name(app)).")
                }
                continue
            }
            if operation.id == "PRESS_RETURN", operation.confidence < 0.5 {
                recent.append(JevClient.RecentAction(action: "PRESS_RETURN", result: "not performed: not sure the goal asks for Return", screenChanged: false))
                noChange += 1
                if noChange >= 3 {
                    return try await halted("unclear", "Not sure whether to press Return next.", pending: PendingAction(operation: "PRESS_RETURN", target: "Return", reason: "The decision was below the confidence floor."))
                }
                continue
            }
            let label = targetCandidate?.label ?? operation.id.replacingOccurrences(of: "_", with: " ").capitalized
            let destructive = operation.id == "QUIT_APP" || (["MENU", "CLICK"].contains(operation.id) && ["quit", "close", "delete", "remove", "trash", "empty", "discard", "clear"].contains { label.lowercased().contains($0) })
            let gate = destructive ? 0.6 : 0.2
            if let target, target.confidence < gate {
                let top = (decision.answers[headName ?? ""]?.probabilities ?? [:]).sorted { $0.value > $1.value }.prefix(3)
                    .compactMap { entry in snapshot.candidates.first { $0.id == entry.key }?.label }
                let listed = top.isEmpty ? label : top.joined(separator: ", ")
                return try await halted("unclear", "Not sure which target. Closest: \(listed).", pending: PendingAction(operation: operation.id, target: top.first ?? label, reason: "Say which one and run the task again. Closest: \(listed)."))
            }
            if !approve, let reason = Policy.confirmationReason(operation: operation.id, label: label, goal: goal) {
                return try await halted("needs_confirmation", reason, pending: PendingAction(operation: operation.id, target: label, reason: reason))
            }
            if let blocked = allowListBlock(operation: operation.id, candidate: targetCandidate, app: app) {
                return try await halted("blocked", blocked, pending: PendingAction(operation: operation.id, target: label, reason: blocked))
            }

            let pick = "\(operation.id)|\(targetCandidate?.id ?? "")"
            if operation.id == "ARRANGE_WINDOWS", pick == lastPick, lastResult.hasPrefix("Arranged") || lastResult.contains("moved to its new place") {
                return try await halted("done", lastResult)
            }
            samePick = pick == lastPick ? samePick + 1 : 0
            lastPick = pick
            if samePick >= 2 && !["SCROLL_DOWN", "SCROLL_UP", "SKIP_FORWARD", "SKIP_BACK"].contains(operation.id) {
                return try await halted("blocked", "Stopped: \(operation.id) \(label) was chosen three times without finishing. Last: \(lastResult)")
            }

            let before = Desktop.fingerprint(of: app)
            let appBefore = app.processIdentifier
            let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let titleBefore = snapshot.windowTitle
            var result: String
            var typed: String?
            var changeWait = 0.25
            let repetitions = decision.noul("counted") >= 0.6 ? count ?? 1 : 1
            do {
                let performed = try await perform(operation: operation.id, candidate: targetCandidate, snapshot: snapshot, label: label, repetitions: repetitions, tokens: goal.split(separator: " ").map(String.init), decision: decision)
                result = performed.result
                typed = performed.typed
                changeWait = performed.changeWait
                if performed.remainingCount == 0 { count = nil }
                else if let remaining = performed.remainingCount { count = remaining }
            } catch let error as DesktopError where error.stale {
                recent.append(JevClient.RecentAction(action: "\(operation.id) \(label)", result: "not performed: the control changed before it could be used", screenChanged: false))
                continue
            }
            if let moved = followApp(after: operation.id, candidate: targetCandidate, snapshot: snapshot, from: app) {
                app = moved
            }
            let opened = ["OPEN_URL", "OPEN_APP", "OPEN_FOLDER"].contains(operation.id)
            let changed = opened ? true : try await Desktop.waitForChange(in: app, from: before, upTo: changeWait)
            if !opened, let front = NSWorkspace.shared.frontmostApplication, Desktop.isControllable(front),
               front.processIdentifier != app.processIdentifier, front.processIdentifier != frontBefore {
                app = front
            }
            if changed, !opened {
                if snapshot.usesWebContent, operation.id == "PRESS_RETURN" || (operation.id != "TYPE_TEXT" && Desktop.describe(app).title != titleBefore) {
                    try await Desktop.waitForPageToSettle(app, timeout: 2)
                } else {
                    try await Desktop.waitForQuiet(in: app, quiet: 0.15, upTo: 0.5)
                }
            }
            let after = Desktop.describe(app)
            windowChanged = after.title != titleBefore
            navigated = operation.id == "OPEN_URL" || (after.title != titleBefore && ["PRESS_RETURN", "CLICK", "GO_BACK"].contains(operation.id))
            if operation.id == "OPEN_URL" { lastOffered = [] }
            let scrolled = result.contains("the content moved")
            let arranged = operation.id == "ARRANGE_WINDOWS" && changed
            let effect = after.title != titleBefore ? "window is now '\(after.title)'" : scrolled ? "new content is on screen"
                : arranged ? "the window moved to its new place" : (changed ? "focus is now \(after.focused)" : noEffect)
            lastClicked = []
            if operation.id == "CLICK", after.title == titleBefore, after.focused.contains(label) || !changed, let id = targetCandidate?.id {
                ineffective.insert(id)
                lastClicked = [id]
            }
            result += " → \(effect)"
            note("cycle \(cycle): \(result)")
            recent.append(JevClient.RecentAction(action: "\(operation.id) \(label)", result: result, screenChanged: after.title != titleBefore))
            trace.actions.append(ActionRecord(operation: operation.id, target: label, result: result))
            trace.application = name(app)
            trace.window = after.title
            lastResult = result
            if app.processIdentifier != appBefore { chain = []; chainWindow = nil }
            let sameWindows = app.processIdentifier != appBefore || Desktop.windows(of: app).count == windowCount
            let perWindow = !["ARRANGE_WINDOWS", "OPEN_APP", "OPEN_FOLDER", "QUIT_APP"].contains(operation.id) && repetitions == 1 && sameWindows
            if perWindow, app.processIdentifier == appBefore || operation.id == "OPEN_URL" {
                let meta = targetCandidate.flatMap { snapshot.meta[$0.id] }
                let alike = snapshot.candidates(of: [.control, .focus]).filter { snapshot.meta[$0.id]?.role == meta?.role && snapshot.meta[$0.id]?.place == meta?.place }
                chain.append(ChainStep(operation: operation.id, label: label, role: meta?.role, place: meta?.place,
                                        ordinal: targetCandidate.flatMap { target in alike.firstIndex { $0.id == target.id } } ?? 0,
                                        text: typed, action: targetCandidate.flatMap { snapshot.actions[$0.id] }, effective: changed))
                chainWindow = Desktop.windows(of: app).first
            }
            let worked = after.title != titleBefore || result.hasPrefix("Typed into") || result.hasPrefix("Opened") || result.contains("the content moved") || result.hasPrefix("Arranged") || arranged
            if decision.noul("finishes") >= 0.8, worked, count == nil, !substituted {
                note("cycle \(cycle): finished without another decision")
                return try await halted("done", result)
            }
            noChange = changed ? 0 : noChange + 1
            if noChange >= 3 {
                return try await halted("blocked", "Stopped: three actions changed nothing. Last: \(result)")
            }
        }
        return try await halted("blocked", "Stopped after \(limit) cycles. Last: \(lastResult)", sure: false)
    }

    private struct Offer {
        var elements: [JevClient.Element]
        var heads: [String: [String: String]]
        var operations: [String: String]
        var available: JevClient.Available
        var inputs: [Candidate]
    }

    private func offer(snapshot: DesktopSnapshot, goalWords: Set<String>, ineffective: Set<String>) -> Offer {
        var elements: [JevClient.Element] = []
        var heads: [String: [String: String]] = [:]
        var operations: [String: String] = [:]
        let toolbarWords: Set<String> = ["tab", "tabs", "address", "bookmark", "bookmarks", "back", "forward", "reload", "toolbar", "extension"]
        let aboutToolbar = !goalWords.isDisjoint(with: toolbarWords)
        let allClicks = snapshot.candidates(of: [.control]).filter { !ineffective.contains($0.id) }
        let pageClicks = allClicks.filter { snapshot.meta[$0.id]?.place == "page" }
        let beside = allClicks.filter { snapshot.meta[$0.id]?.place == nil }
        let clicks = (aboutToolbar || pageClicks.isEmpty) ? allClicks : pageClicks + beside
        let inputs = snapshot.candidates(of: [.focus])
        let offeredClicks = trimmed(clicks, words: goalWords, limit: max(50, 250 - inputs.count))
        for candidate in offeredClicks + inputs {
            guard let meta = snapshot.meta[candidate.id] else { continue }
            let ops = snapshot.kinds[candidate.id] == .focus ? ["TYPE_TEXT", "CLICK"] : ["CLICK"]
            elements.append(JevClient.Element(index: meta.index, role: meta.role, label: candidate.label, value: meta.value, place: meta.place, operations: ops))
        }
        if !clicks.isEmpty {
            heads["click_target"] = Dictionary(uniqueKeysWithValues: (offeredClicks + inputs).map { ($0.id, $0.detail) })
            operations["CLICK"] = "Click or press the control chosen in click_target."
        }
        let tokens = goal.split(separator: " ").map(String.init)
        if !inputs.isEmpty {
            var typeTargets = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.detail) })
            typeTargets["none"] = "None of the offered inputs is the one the goal means. The right input still has to be opened or revealed."
            heads["type_target"] = typeTargets
            operations["TYPE_TEXT"] = "Enter into the input chosen in type_target the text that runs from the word chosen in type_from to the word chosen in type_to. This does not submit."
            var wordOptions: [String: String] = [:]
            for (index, token) in tokens.enumerated() {
                let before = index > 0 ? tokens[index - 1] + " " : ""
                let after = index + 1 < tokens.count ? " " + tokens[index + 1] : ""
                wordOptions["w\(index)"] = "word \(index + 1) of \(tokens.count): …\(before)[\(token)]\(after)…"
            }
            heads["type_from"] = wordOptions
            heads["type_to"] = wordOptions
        }
        let apps = snapshot.candidates(of: [.app])
        if !apps.isEmpty {
            heads["app_target"] = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.detail) })
            operations["OPEN_APP"] = "Open or switch to the application chosen in app_target."
        }
        let sites = snapshot.candidates(of: [.website])
        if !sites.isEmpty {
            heads["url_target"] = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0.detail) })
            operations["OPEN_URL"] = "Open the website named in the goal, using the browser chosen in url_target."
        }
        let folders = snapshot.candidates(of: [.folder])
        if !folders.isEmpty {
            heads["folder_target"] = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.detail) })
            operations["OPEN_FOLDER"] = "Open the folder chosen in folder_target."
        }
        let menus = snapshot.candidates(of: [.menu]).filter { candidate in
            goalWords.contains { candidate.label.lowercased().contains($0) } || ["close", "quit", "new", "save", "undo", "find", "reload"].contains { candidate.label.lowercased().contains($0) }
        }
        if !menus.isEmpty {
            heads["menu_target"] = Dictionary(uniqueKeysWithValues: trimmed(menus, words: goalWords, limit: 120).map { ($0.id, $0.detail) })
            operations["MENU"] = "Choose the app menu item chosen in menu_target."
        }
        let quits = snapshot.candidates(of: [.quit])
        if !quits.isEmpty {
            heads["quit_target"] = Dictionary(uniqueKeysWithValues: quits.map { ($0.id, $0.detail) })
            operations["QUIT_APP"] = "Quit the running application chosen in quit_target."
        }
        operations["PRESS_RETURN"] = "Press Return. This submits the focused input or search box."
        operations["PRESS_ESCAPE"] = "Press Escape. This closes a menu, dialog, or full-screen view."
        operations["SCROLL_DOWN"] = "Scroll down one screen in the current window."
        operations["SCROLL_UP"] = "Scroll up one screen in the current window."
        operations["SKIP_FORWARD"] = "Skip a playing video or track forward 5 seconds."
        operations["SKIP_BACK"] = "Skip a playing video or track back 5 seconds."
        operations["GO_BACK"] = "Go back to the previous page or folder."
        operations["NEXT_TAB"] = "Switch to the next tab."
        let arrangements = snapshot.candidates(of: [.window])
        if !arrangements.isEmpty {
            heads["arrange_target"] = Dictionary(uniqueKeysWithValues: arrangements.map { ($0.id, $0.detail) })
            operations["ARRANGE_WINDOWS"] = "Move and resize windows as chosen in arrange_target."
        }
        operations["WAIT"] = "Wait briefly because the needed control is absent or results are still loading."
        operations["DONE"] = "Every part of the goal is visibly satisfied."
        operations["BLOCKED"] = "No offered operation can make progress on the goal."
        let available = JevClient.Available(apps: apps.map(\.label), folders: folders.map(\.label), sites: sites.map(\.label), menus: menus.map(\.label))
        return Offer(elements: elements, heads: heads, operations: operations, available: available, inputs: inputs)
    }

    private struct Performed {
        var result: String
        var typed: String?
        var changeWait: Double
        var remainingCount: Int?
    }

    private func perform(operation: String, candidate: Candidate?, snapshot: DesktopSnapshot, label: String, repetitions: Int, tokens: [String], decision: Decision) async throws -> Performed {
        if repetitions > 1, ["CLICK", "MENU", "NEXT_TAB", "GO_BACK", "PRESS_RETURN", "PRESS_ESCAPE"].contains(operation) {
            let action = candidate.flatMap { snapshot.actions[$0.id] } ?? .key(["NEXT_TAB": 48, "GO_BACK": 33, "PRESS_RETURN": 36][operation] ?? 53, operation == "NEXT_TAB" ? .maskControl : operation == "GO_BACK" ? .maskCommand : [])
            var performed = 0
            do {
                for _ in 0..<repetitions {
                    _ = try await Desktop.perform(action, label: label, snapshot: snapshot)
                    performed += 1
                }
            } catch let error as DesktopError where error.stale && performed > 0 {}
            let remaining: Int? = performed < repetitions ? repetitions - performed : 0
            return Performed(result: "\(label): performed \(performed) of the \(repetitions) times the goal asks", typed: nil, changeWait: 0.25, remainingCount: remaining)
        }
        switch operation {
        case "CLICK", "OPEN_APP", "OPEN_FOLDER", "MENU", "QUIT_APP", "OPEN_URL", "ARRANGE_WINDOWS":
            guard let candidate else { throw DecisionError.invalidResponse }
            let result = try await Desktop.perform(candidate, snapshot: snapshot)
            let wait = ["OPEN_APP", "OPEN_URL", "OPEN_FOLDER"].contains(operation) ? 1.0 : 0.25
            return Performed(result: result, typed: nil, changeWait: wait, remainingCount: nil)
        case "TYPE_TEXT":
            guard let candidate, case .focus(let element, _) = snapshot.actions[candidate.id] else { throw DecisionError.invalidResponse }
            let from = decision.choice("type_from").flatMap { Int($0.id.dropFirst()) }
            let to = decision.choice("type_to").flatMap { Int($0.id.dropFirst()) }
            let chosen: String?
            if let from, let to, tokens.indices.contains(from), tokens.indices.contains(to) {
                chosen = from <= to ? tokens[from...to].joined(separator: " ") : tokens[from]
            } else if let from, tokens.indices.contains(from) {
                chosen = tokens[from]
            } else {
                chosen = nil
            }
            let text = (chosen ?? Self.searchWords(from: goal)).trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
            guard !text.isEmpty else { throw DesktopError(message: "Nothing to type. Name the text in the goal.") }
            var result = try await Desktop.perform(.type(text, element), label: candidate.label, snapshot: snapshot)
            result += " ('\(text)')"
            return Performed(result: result, typed: text, changeWait: 0.25, remainingCount: nil)
        case "PRESS_RETURN":
            return Performed(result: try await Desktop.press(key: 36, times: 1, in: snapshot.application), typed: nil, changeWait: 0.6, remainingCount: nil)
        case "PRESS_ESCAPE":
            return Performed(result: try await Desktop.press(key: 53, times: 1, in: snapshot.application), typed: nil, changeWait: 0.25, remainingCount: nil)
        case "SCROLL_DOWN":
            return Performed(result: try await Desktop.scroll(down: true, times: repetitions, in: snapshot.application), typed: nil, changeWait: 0.25, remainingCount: 0)
        case "SCROLL_UP":
            return Performed(result: try await Desktop.scroll(down: false, times: repetitions, in: snapshot.application), typed: nil, changeWait: 0.25, remainingCount: 0)
        case "SKIP_FORWARD":
            return Performed(result: try await Desktop.press(key: 124, times: repetitions, in: snapshot.application), typed: nil, changeWait: 0.25, remainingCount: 0)
        case "SKIP_BACK":
            return Performed(result: try await Desktop.press(key: 123, times: repetitions, in: snapshot.application), typed: nil, changeWait: 0.25, remainingCount: 0)
        case "GO_BACK":
            return Performed(result: try await Desktop.perform(.key(33, .maskCommand), label: "Go back", snapshot: snapshot), typed: nil, changeWait: 0.25, remainingCount: nil)
        case "NEXT_TAB":
            return Performed(result: try await Desktop.perform(.key(48, .maskControl), label: "Next tab", snapshot: snapshot), typed: nil, changeWait: 0.25, remainingCount: nil)
        default:
            throw DecisionError.invalidResponse
        }
    }

    private func followApp(after operation: String, candidate: Candidate?, snapshot: DesktopSnapshot, from app: NSRunningApplication) -> NSRunningApplication? {
        func running(_ url: URL) -> NSRunningApplication? {
            NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && Desktop.isControllable($0) }
        }
        switch candidate.flatMap({ snapshot.actions[$0.id] }) {
        case .application(let url), .website(_, browser: let url):
            return running(url) ?? app
        case .folder:
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first ?? app
        default:
            return ["OPEN_URL", "OPEN_APP", "OPEN_FOLDER"].contains(operation) ? app : nil
        }
    }

    private func allowListBlock(operation: String, candidate: Candidate?, app: NSRunningApplication) -> String? {
        guard !allow.isEmpty else { return nil }
        if ["DONE", "WAIT", "BLOCKED"].contains(operation) { return nil }
        let list = allow.joined(separator: ", ")
        switch operation {
        case "OPEN_APP", "QUIT_APP":
            let target = candidate?.label ?? "that app"
            if !Policy.appAllowed(target, allow: allow) {
                return "\(target) is outside the allow list (\(list))."
            }
        case "OPEN_URL":
            let browser = candidate.flatMap { Policy.browserName(in: $0.label) } ?? "the browser"
            if !Policy.appAllowed(browser, allow: allow) {
                return "Opening a site in \(browser) is outside the allow list (\(list))."
            }
        case "OPEN_FOLDER":
            if !Policy.appAllowed("Finder", allow: allow) {
                return "Opening a folder uses Finder, which is outside the allow list (\(list))."
            }
        default:
            let current = app.localizedName ?? "This app"
            if !Policy.appAllowed(current, allow: allow) {
                return "\(current) is outside the allow list (\(list))."
            }
        }
        return nil
    }

    private func replay(_ chain: [ChainStep], in app: NSRunningApplication, except recorded: AXUIElement?) async throws -> String {
        let others = Desktop.windows(of: app).filter { window in recorded.map { !CFEqual($0, window) } ?? true }
        guard !others.isEmpty else { return "Done in this window. There are no other windows." }
        var failed = Set<Int>()
        for step in chain {
            for (index, window) in others.enumerated() where !failed.contains(index) {
                try Task.checkCancellation()
                note("repeat \(step.label) in window \(index + 2)")
                try await Desktop.raise(window, of: app)
                do {
                    try await replayStep(step, in: app)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed.insert(index)
                    note("repeat failed in window \(index + 2): \(error.localizedDescription)")
                }
            }
        }
        return "Repeated \(chain.count) steps in \(others.count - failed.count) of \(others.count) other windows."
    }

    private func replayStep(_ step: ChainStep, in app: NSRunningApplication) async throws {
        switch (step.operation, step.action) {
        case ("OPEN_URL", .website(let url, let browser)?):
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
            try await Task.sleep(nanoseconds: 150_000_000)
        case ("PRESS_RETURN", _):
            _ = try await Desktop.press(key: 36, times: 1, in: app)
        case ("PRESS_ESCAPE", _):
            _ = try await Desktop.press(key: 53, times: 1, in: app)
        case ("SKIP_FORWARD", _):
            _ = try await Desktop.press(key: 124, times: 1, in: app)
        case ("SKIP_BACK", _):
            _ = try await Desktop.press(key: 123, times: 1, in: app)
        case ("SCROLL_DOWN", _):
            _ = try await Desktop.scroll(down: true, times: 1, in: app)
        case ("SCROLL_UP", _):
            _ = try await Desktop.scroll(down: false, times: 1, in: app)
        case ("GO_BACK", _), ("NEXT_TAB", _), ("MENU", _):
            let snapshot = try await Desktop.capture(application: app, command: "", includeMenus: false)
            let action = step.action ?? .key(step.operation == "NEXT_TAB" ? 48 : 33, step.operation == "NEXT_TAB" ? .maskControl : .maskCommand)
            _ = try await Desktop.perform(action, label: step.label, snapshot: snapshot)
        default:
            var found: (Candidate, DesktopSnapshot)?
            for attempt in 0..<12 where found == nil {
                if attempt > 0 { try await Task.sleep(nanoseconds: 400_000_000) }
                let snapshot = try await Desktop.capture(application: app, command: "", includeMenus: false)
                let pool = snapshot.candidates(of: step.operation == "TYPE_TEXT" ? [.focus] : [.control, .focus])
                let alike = pool.filter { snapshot.meta[$0.id]?.role == step.role && snapshot.meta[$0.id]?.place == step.place }
                func parts(_ label: String) -> (name: String, turn: Int) {
                    guard label.hasSuffix(")"), let open = label.range(of: " (", options: .backwards), let of = label.range(of: " of ", options: .backwards),
                          open.upperBound <= of.lowerBound, let turn = Int(label[open.upperBound..<of.lowerBound]) else { return (label, 1) }
                    return (String(label[..<open.lowerBound]), turn)
                }
                let wanted = parts(step.label)
                let named = pool.filter { parts($0.label).name == wanted.name }
                if let same = pool.first(where: { $0.label == step.label }) { found = (same, snapshot) }
                else if let same = named.first(where: { parts($0.label).turn == wanted.turn }) ?? (named.count == 1 ? named.first : nil) { found = (same, snapshot) }
                else if attempt >= 3, step.ordinal < alike.count { found = (alike[step.ordinal], snapshot) }
            }
            guard let (target, snapshot) = found else { throw DesktopError(message: "'\(step.label)' did not appear") }
            if step.operation == "TYPE_TEXT", let text = step.text, case .focus(let element, _)? = snapshot.actions[target.id] {
                _ = try await Desktop.perform(.type(text, element), label: target.label, snapshot: snapshot)
            } else {
                _ = try await Desktop.perform(target, snapshot: snapshot)
            }
        }
    }

    private func trimmed(_ list: [Candidate], words: Set<String>, limit: Int) -> [Candidate] {
        guard list.count > limit else { return list }
        let relevant = list.filter { candidate in words.contains { candidate.label.lowercased().contains($0) } }
        let rest = list.filter { candidate in !relevant.contains(candidate) }
        return Array((relevant + rest).prefix(limit))
    }

    private func name(_ app: NSRunningApplication) -> String { app.localizedName ?? "the app" }

    private func note(_ line: String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func report(status: String, summary: String, application: String = "", window: String = "", actions: [ActionRecord], pending: PendingAction?, seconds: Double) -> RunReport {
        RunReport(status: status, summary: summary, application: application, window: window, actions: actions, pending: pending, decisionSeconds: (seconds * 100).rounded() / 100)
    }

    private static func searchWords(from goal: String) -> String {
        let stop: Set<String> = ["go", "to", "on", "open", "search", "for", "look", "up", "type", "in", "into", "the", "and", "then", "click", "first", "video", "play", "press", "enter", "return", "a", "an", "please", "can", "you", "it", "this", "that", "result", "results"]
        return goal.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
            .filter { word in !stop.contains(word.lowercased()) && !word.lowercased().contains(".") }
            .joined(separator: " ")
    }
}
