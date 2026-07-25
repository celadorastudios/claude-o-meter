import Foundation

/// Standalone CLI tool for generating team spend reports and posting to Slack.
/// Reads Claude Code JSONL transcripts directly — no dependency on the GUI app.
///
/// Usage:
///   claude-o-meter-report [--slack <webhook-url>] [--root <path>] [--days <n>] [--json]
///
/// Without --slack, prints the report to stdout.
/// With --slack, posts a formatted message to the given Slack webhook URL.
///
/// Examples:
///   swift run ClaudeOMeterReport --root ~/.claude
///   swift run ClaudeOMeterReport --slack https://hooks.slack.com/services/T.../B.../xxx --days 7

// MARK: - Config

struct ReportConfig {
    var slackWebhookURL: String?
    var rootPath: String?
    var days: Int = 1
    var jsonOutput: Bool = false
    var threshold: Double = 100.0
}

func parseArgs() -> ReportConfig {
    var config = ReportConfig()
    var args = Array(CommandLine.arguments.dropFirst())
    var i = 0

    while i < args.count {
        switch args[i] {
        case "--slack":
            i += 1; if i < args.count { config.slackWebhookURL = args[i] }
        case "--root":
            i += 1; if i < args.count { config.rootPath = args[i] }
        case "--days":
            i += 1; if i < args.count { config.days = Int(args[i]) ?? 1 }
        case "--threshold":
            i += 1; if i < args.count { config.threshold = Double(args[i]) ?? 100.0 }
        case "--json":
            config.jsonOutput = true
        case "--help", "-h":
            printUsage(); exit(0)
        default:
            break
        }
        i += 1
    }
    return config
}

func printUsage() {
    print("""
    claude-o-meter-report — Team spend digest from Claude Code transcripts

    OPTIONS:
      --root <path>       Claude config dir (default: ~/.claude)
      --days <n>          Days to include in report (default: 1 = yesterday)
      --slack <url>       Post to Slack webhook instead of stdout
      --threshold <usd>   Flag projects over this amount (default: 100)
      --json              Output as JSON instead of formatted text
      --help              Show this help
    """)
}

// MARK: - Transcript Scanning (standalone, no GUI dependency)

struct TokenCost {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite5m: Int = 0
    var cacheWrite1h: Int = 0
}

struct UsageEntry {
    let id: String
    let day: String
    let model: String
    let tokens: TokenCost
    let projectDir: String
}

func resolveRoot(_ override: String?) -> URL {
    if let path = override {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).appendingPathComponent("projects", isDirectory: true)
    }
    if let envDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !envDir.isEmpty {
        return URL(fileURLWithPath: envDir).appendingPathComponent("projects", isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
}

func normalizeModel(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("synthetic") { return "synthetic" }
    if lower.contains("fable") || lower.contains("mythos") { return "fable" }
    if lower.contains("opus") { return "opus" }
    if lower.contains("sonnet") { return "sonnet" }
    if lower.contains("haiku") { return "haiku" }
    return "unknown"
}

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoNoFracFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func localDay(from date: Date) -> String {
    dayFormatter.string(from: date)
}

func localDay(fromISO ts: String) -> String? {
    guard let date = isoFormatter.date(from: ts) ?? isoNoFracFormatter.date(from: ts) else { return nil }
    return localDay(from: date)
}

func dayAgo(_ n: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date()
    return localDay(from: d)
}

func scanTranscripts(root: URL, targetDays: Set<String>) -> [UsageEntry] {
    var entries: [UsageEntry] = []
    var seen = Set<String>()

    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        fputs("Warning: Cannot access \(root.path)\n", stderr)
        return []
    }

    for case let url as URL in enumerator {
        guard url.pathExtension == "jsonl" else { continue }
        let projectDir = url.deletingLastPathComponent().lastPathComponent

        guard let data = try? Data(contentsOf: url) else { continue }

        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let id = message["id"] as? String,
                  let ts = obj["timestamp"] as? String,
                  let day = localDay(fromISO: ts),
                  targetDays.contains(day),
                  !seen.contains(id)
            else { continue }

            seen.insert(id)
            let rawModel = (message["model"] as? String) ?? "unknown"
            let model = normalizeModel(rawModel)
            if model == "synthetic" { continue }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let cacheWriteTotal = (usage["cache_creation_input_tokens"] as? Int) ?? 0

            var write5m = cacheWriteTotal
            var write1h = 0
            if let breakdown = usage["cache_creation"] as? [String: Any] {
                let b5 = (breakdown["ephemeral_5m_input_tokens"] as? Int) ?? 0
                let b1 = (breakdown["ephemeral_1h_input_tokens"] as? Int) ?? 0
                if b5 + b1 > 0 { write5m = b5; write1h = b1 }
            }

            entries.append(UsageEntry(
                id: id, day: day, model: model,
                tokens: TokenCost(input: input, output: output, cacheRead: cacheRead, cacheWrite5m: write5m, cacheWrite1h: write1h),
                projectDir: projectDir
            ))
        }
    }

    return entries
}

// MARK: - Pricing (hardcoded defaults matching the app)

struct ModelPrice {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
}

let prices: [String: ModelPrice] = [
    "fable":  ModelPrice(input: 10, output: 50, cacheRead: 1.0, cacheWrite5m: 12.5, cacheWrite1h: 20.0),
    "opus":   ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10.0),
    "sonnet": ModelPrice(input: 3,  output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6.0),
    "haiku":  ModelPrice(input: 1,  output: 5,  cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2.0),
]

func cost(of tokens: TokenCost, model: String) -> Double {
    let p = prices[model] ?? prices["opus"]!
    let perM = 1_000_000.0
    return (Double(tokens.input) / perM * p.input) +
           (Double(tokens.output) / perM * p.output) +
           (Double(tokens.cacheRead) / perM * p.cacheRead) +
           (Double(tokens.cacheWrite5m) / perM * p.cacheWrite5m) +
           (Double(tokens.cacheWrite1h) / perM * p.cacheWrite1h)
}

// MARK: - Report Generation

struct TeamReport: Codable {
    let period: String
    let totalCost: Double
    let topProjects: [ProjectCost]
    let modelBreakdown: [ModelCost]
    let projectsOverThreshold: Int
    let threshold: Double

    struct ProjectCost: Codable { let name: String; let cost: Double }
    struct ModelCost: Codable { let model: String; let cost: Double }
}

func projectDisplayName(from encodedDir: String) -> String {
    guard !encodedDir.isEmpty else { return "Unknown" }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let encodedHome = String(home.dropFirst())
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ".", with: "-")
    let withoutLeadingDash = encodedDir.hasPrefix("-") ? String(encodedDir.dropFirst()) : encodedDir
    if withoutLeadingDash.hasPrefix(encodedHome) {
        let remainder = String(withoutLeadingDash.dropFirst(encodedHome.count))
        let relative = remainder.hasPrefix("-") ? String(remainder.dropFirst()) : remainder
        if !relative.isEmpty { return relative }
    }
    return withoutLeadingDash
}

func generateReport(config: ReportConfig) -> TeamReport {
    let root = resolveRoot(config.rootPath)
    let targetDays = Set((1...config.days).map { dayAgo($0) })
    let period = config.days == 1 ? "yesterday (\(dayAgo(1)))" : "last \(config.days) days"

    fputs("Scanning \(root.path) for \(targetDays.count) day(s)...\n", stderr)
    let entries = scanTranscripts(root: root, targetDays: targetDays)
    fputs("Found \(entries.count) usage entries.\n", stderr)

    var totalCost = 0.0
    var projectCosts: [String: Double] = [:]
    var modelCosts: [String: Double] = [:]

    for entry in entries {
        let c = cost(of: entry.tokens, model: entry.model)
        totalCost += c
        let projName = projectDisplayName(from: entry.projectDir)
        projectCosts[projName, default: 0] += c
        modelCosts[entry.model, default: 0] += c
    }

    let topProjects = projectCosts
        .sorted { $0.value > $1.value }
        .prefix(5)
        .map { TeamReport.ProjectCost(name: $0.key, cost: round($0.value * 100) / 100) }

    let modelBreakdown = modelCosts
        .sorted { $0.value > $1.value }
        .map { TeamReport.ModelCost(model: $0.key, cost: round($0.value * 100) / 100) }

    let projectsOver = projectCosts.values.filter { $0 > config.threshold }.count

    return TeamReport(
        period: period,
        totalCost: round(totalCost * 100) / 100,
        topProjects: topProjects,
        modelBreakdown: modelBreakdown,
        projectsOverThreshold: projectsOver,
        threshold: config.threshold
    )
}

// MARK: - Output Formatting

func formatSlackMessage(_ report: TeamReport) -> String {
    var lines: [String] = []
    lines.append(":chart_with_upwards_trend: *Claude Code Spend Report — \(report.period)*")
    lines.append("")
    lines.append("*Total:* $\(String(format: "%.2f", report.totalCost))")

    if !report.topProjects.isEmpty {
        lines.append("")
        lines.append("*Top projects:*")
        for proj in report.topProjects {
            lines.append("• \(proj.name) — $\(String(format: "%.2f", proj.cost))")
        }
    }

    if !report.modelBreakdown.isEmpty {
        lines.append("")
        lines.append("*By model:*")
        for m in report.modelBreakdown {
            lines.append("• \(m.model): $\(String(format: "%.2f", m.cost))")
        }
    }

    if report.projectsOverThreshold > 0 {
        lines.append("")
        lines.append(":warning: \(report.projectsOverThreshold) project(s) over $\(Int(report.threshold))")
    }

    return lines.joined(separator: "\n")
}

func postToSlack(webhookURL: String, message: String) {
    guard let url = URL(string: webhookURL) else {
        fputs("Error: Invalid webhook URL\n", stderr)
        exit(1)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let payload: [String: Any] = ["text": message]
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    let semaphore = DispatchSemaphore(value: 0)
    var responseError: Error?

    URLSession.shared.dataTask(with: request) { _, response, error in
        if let error { responseError = error }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            responseError = NSError(domain: "Slack", code: http.statusCode,
                                   userInfo: [NSLocalizedDescriptionKey: "Slack returned HTTP \(http.statusCode)"])
        }
        semaphore.signal()
    }.resume()

    semaphore.wait()

    if let error = responseError {
        fputs("Error posting to Slack: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// MARK: - Main

let config = parseArgs()
let report = generateReport(config: config)

if config.jsonOutput {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(data: data, encoding: .utf8) ?? "{}")
    } catch {
        fputs("Error encoding JSON: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else if let webhook = config.slackWebhookURL {
    let message = formatSlackMessage(report)
    postToSlack(webhookURL: webhook, message: message)
    fputs("Report posted to Slack.\n", stderr)
} else {
    print(formatSlackMessage(report))
}
