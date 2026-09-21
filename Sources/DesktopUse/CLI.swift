import AppKit
import Foundation

@main
struct DesktopUseCLI {
    static func main() async {
        let code = await CLI().run()
        if code != 0 { exit(code) }
    }
}

struct CLI {
    func run() async -> Int32 {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            fputs(usage, stderr)
            return 1
        }
        args.removeFirst()
        switch command {
        case "help", "-h", "--help":
            fputs(usage, stderr)
            return 0
        case "self-check":
            return selfCheck()
        case "access":
            return await access(args)
        case "key":
            return keyStatus(args)
        case "run":
            return await runTask(args)
        default:
            fputs("Unknown command '\(command)'.\n\(usage)", stderr)
            return 1
        }
    }

    private func selfCheck() -> Int32 {
        let failures = Policy.selfCheck()
        if failures.isEmpty {
            print("ok")
            return 0
        }
        for failure in failures { fputs(failure + "\n", stderr) }
        return 1
    }

    private func access(_ args: [String]) async -> Int32 {
        let prompt = args.contains("--prompt")
        if prompt {
            await MainActor.run { Desktop.requestAccess() }
        }
        let trusted = AXIsProcessTrusted()
        let path = CommandLine.arguments[0]
        let report = AccessReport(trusted: trusted, binary: path, settings: "System Settings → Privacy & Security → Accessibility")
        emit(report)
        return trusted ? 0 : 4
    }

    private func keyStatus(_ args: [String]) -> Int32 {
        guard args.isEmpty || args == ["status"] else {
            fputs("Usage: desktop-use key status\n", stderr)
            return 1
        }
        let present = Self.gatewayKey != nil
        emit(KeyReport(environment: present))
        return present ? 0 : 1
    }

    private func runTask(_ args: [String]) async -> Int32 {
        let parsed: Parsed
        do { parsed = try Parsed(args) } catch {
            fputs(error.localizedDescription + "\n\(usage)", stderr)
            return 1
        }
        guard !parsed.goal.isEmpty else {
            fputs("A goal is required.\n\(usage)", stderr)
            return 1
        }
        await MainActor.run { _ = NSApplication.shared.setActivationPolicy(.accessory) }
        guard AXIsProcessTrusted() else {
            let path = CommandLine.arguments[0]
            let summary = "Accessibility is not granted for \(path). Enable it in System Settings → Privacy & Security → Accessibility, or run desktop-use access --prompt."
            emit(RunReport(status: "error", summary: summary, application: "", window: "", actions: [], pending: nil, decisionSeconds: 0))
            return 4
        }
        guard let apiKey = Self.gatewayKey else {
            emit(RunReport(status: "error", summary: "No Vercel AI Gateway key. Set AI_GATEWAY_API_KEY in the environment.", application: "", window: "", actions: [], pending: nil, decisionSeconds: 0))
            return 1
        }
        let report = await Task { @MainActor in
            await Session(goal: parsed.goal, allow: parsed.allow, approve: parsed.approve, maxSteps: parsed.maxSteps, verbose: parsed.verbose, apiKey: apiKey).run()
        }.value
        emit(report)
        return report.exitCode
    }

    private static var gatewayKey: String? {
        let value = ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            fputs("Could not encode the result.\n", stderr)
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private struct AccessReport: Encodable {
    var trusted: Bool
    var binary: String
    var settings: String
}

private struct KeyReport: Encodable {
    var environment: Bool
}

private struct Parsed {
    var goal = ""
    var allow: [String] = []
    var approve = false
    var maxSteps = 14
    var verbose = false

    init(_ args: [String]) throws {
        var index = 0
        var words: [String] = []
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--approve":
                approve = true
            case "--verbose":
                verbose = true
            case "--goal", "--allow", "--max-steps":
                index += 1
                guard index < args.count else { throw DesktopError(message: "\(arg) needs a value.") }
                let value = args[index]
                switch arg {
                case "--goal":
                    goal = value
                case "--allow":
                    allow = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                case "--max-steps":
                    guard let steps = Int(value), steps > 0 else { throw DesktopError(message: "--max-steps needs a positive integer.") }
                    maxSteps = steps
                default:
                    break
                }
            case "--":
                words.append(contentsOf: args[(index + 1)...])
                index = args.count - 1
            default:
                if arg.hasPrefix("--") { throw DesktopError(message: "Unknown option \(arg).") }
                words.append(arg)
            }
            index += 1
        }
        if goal.isEmpty { goal = words.joined(separator: " ") }
    }
}

private let usage = """
desktop-use runs one macOS task through the Accessibility tree and prints JSON.

  desktop-use run --goal "Open Notes and type hello"
  desktop-use run --allow Notes,Finder --goal "Open Notes"
  desktop-use run --approve --goal "Send the draft"
  desktop-use access [--prompt]
  desktop-use key status
  desktop-use self-check

Jev is called through Vercel AI Gateway. The key is AI_GATEWAY_API_KEY in the environment. Do not put the key in the goal.
Send, post, delete, pay, publish, and quit stop until the same goal is run again with --approve.
--allow limits which apps may be touched. An empty allow list means every app.

"""
