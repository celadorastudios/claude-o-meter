import Foundation

/// Reads Claude Code transcripts incrementally and emits deduplicated usage records.
///
/// Files are append-only within a session, so we track a per-file byte cursor and only
/// parse newly appended bytes. We never advance past the last newline, so a line still
/// being written mid-scan is re-read (whole) on the next pass.
struct TranscriptScanner: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.rootDirectory = rootDirectory
    }

    struct Result: Sendable {
        var records: [UsageRecord]
        var state: ScanState
        var existingPaths: Set<String>
        var concurrency: ConcurrencyStats
    }

    /// Scan all transcripts, mutating `state` cursors/seen-ids and returning new records.
    func scan(state inputState: ScanState) -> Result {
        var state = inputState
        var records: [UsageRecord] = []

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Result(records: [], state: state, existingPaths: [], concurrency: ConcurrencyStats())
        }

        var existingPaths = Set<String>()

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let path = url.path
            let projectDir = url.deletingLastPathComponent().lastPathComponent
            existingPaths.insert(path)

            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let fileSize = UInt64(size)
            var cursor = state.cursors[path] ?? 0

            // File truncated/rotated -> re-read from start.
            if fileSize < cursor { cursor = 0 }
            if fileSize == cursor { continue }

            guard let handle = (try? FileHandle(forReadingFrom: url)) else {
                AppLog.shared.warning("cannot open \(path)", category: "scan")
                continue
            }
            defer { try? handle.close() }
            do { try handle.seek(toOffset: cursor) } catch { continue }
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { continue }

            // Only consume up to the last newline so partial trailing lines are re-read later.
            guard let lastNL = data.lastIndex(of: 0x0A) else { continue }
            let consumable = data[data.startIndex...lastNL]
            let newCursor = cursor + UInt64(consumable.count)

            // Accumulate candidates keyed by message.id — last occurrence wins within this
            // batch of new bytes, so a streamed response's final (most complete) entry is kept.
            var batchByID: [String: UsageRecord] = [:]
            for lineData in consumable.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let rec = Self.parseCandidate(Data(lineData)) {
                    batchByID[rec.id] = rec
                }
            }

            // Emit only records not yet seen globally; mark them seen.
            for var rec in batchByID.values {
                guard state.seenIDs[rec.id] == nil else { continue }
                state.seenIDs[rec.id] = rec.day
                rec = UsageRecord(id: rec.id, day: rec.day, hour: rec.hour, model: rec.model,
                                  rawModel: rec.rawModel, usage: rec.usage, projectDir: projectDir)
                records.append(rec)
            }

            state.cursors[path] = newCursor
        }

        let today = DayBucket.localDay(from: Date())
        let concurrency = Self.scanConcurrency(for: today, rootDirectory: rootDirectory)
        return Result(records: records, state: state, existingPaths: existingPaths, concurrency: concurrency)
    }

    /// Compute concurrency stats for `day` by walking JSONL files modified today and binning
    /// usage-event timestamps into 5-minute buckets. Files last modified before `day` are
    /// skipped to avoid re-reading the entire historical archive on every scan cycle.
    static func scanConcurrency(for day: String, rootDirectory: URL) -> ConcurrencyStats {
        let bucketSize = 5  // minutes per bucket
        var bucketUser:     [Int: Set<String>] = [:]  // bucket -> user session IDs
        var bucketAgents:   [Int: Set<String>] = [:]  // bucket -> subagent session IDs
        var bucketProjects: [Int: Set<String>] = [:]  // bucket -> project dirs (user only)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ConcurrencyStats() }

        // Skip files not touched today — they cannot contain today's timestamps.
        let dayStart = Calendar.current.startOfDay(for: Date())
        let rootComponents = rootDirectory.pathComponents

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }

            // Fast-path: skip historical files to avoid reading the whole archive every cycle.
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod = modDate, mod < dayStart { continue }

            let allComponents = url.pathComponents
            let rel = Array(allComponents.dropFirst(rootComponents.count))
            guard rel.count >= 2 else { continue }

            let projectDir = rel[0]
            let isSubagent = rel.contains("subagents")
            let sessionId  = url.deletingPathExtension().lastPathComponent

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let data = handle.readDataToEndOfFile()

            for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                      let ts  = obj["timestamp"] as? String,
                      ts.hasPrefix(day),
                      ts.count >= 16,  // guard against malformed timestamps before index arithmetic
                      let msg = obj["message"] as? [String: Any],
                      msg["usage"] != nil
                else { continue }

                // Extract "HH:MM" safely from "YYYY-MM-DDTHH:MM:SS.sssZ"
                let timeParts = ts.dropFirst(11).prefix(5).split(separator: ":")
                guard timeParts.count == 2,
                      let hour = Int(timeParts[0]),
                      let minute = Int(timeParts[1])
                else { continue }

                let bucket = ((hour * 60 + minute) / bucketSize) * bucketSize

                if isSubagent {
                    bucketAgents[bucket, default: []].insert(sessionId)
                } else {
                    bucketUser[bucket, default: []].insert(sessionId)
                    bucketProjects[bucket, default: []].insert(projectDir)
                }
            }
        }

        // Find peak user-session bucket
        var peakUserSessions = 0
        var peakProjectDirs: Set<String> = []
        for (bucket, sessions) in bucketUser {
            if sessions.count > peakUserSessions {
                peakUserSessions = sessions.count
                peakProjectDirs  = bucketProjects[bucket] ?? []
            }
        }

        let peakSubagents    = bucketAgents.values.map(\.count).max() ?? 0
        let peakProjectNames = peakProjectDirs.map { projectDisplayName(from: $0) }.sorted()

        return ConcurrencyStats(
            peakUserSessions: peakUserSessions,
            peakSubagents:    peakSubagents,
            peakProjectNames: peakProjectNames
        )
    }

    /// Parse one JSONL line into a candidate record without mutating scan state.
    /// Returns nil for non-usage lines (human turns, tool results, etc.).
    static func parseCandidate(_ data: Data) -> UsageRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usageDict = message["usage"] as? [String: Any],
              let id = message["id"] as? String,
              let ts = obj["timestamp"] as? String,
              let day = DayBucket.localDay(fromISO: ts)
        else { return nil }

        let rawModel = (message["model"] as? String) ?? "unknown"
        let family = ModelNormalizer.family(for: rawModel)
        let usage = parseUsage(usageDict)
        let hour = DayBucket.date(fromISO: ts).map { Calendar.current.component(.hour, from: $0) } ?? 0
        return UsageRecord(id: id, day: day, hour: hour, model: family, rawModel: rawModel, usage: usage, projectDir: "")
    }

    /// Derive a human-readable project name from an encoded Claude project directory name.
    /// Claude encodes absolute paths by replacing `/` and `.` with `-`, with a leading `-`.
    /// We strip the encoded home-directory prefix and return the relative portion.
    static func projectDisplayName(from encodedDir: String) -> String {
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

    /// Scan all JSONL files for a given local calendar day and return per-hour cost slices.
    /// Reads only files whose modification date falls on or after the target day to skip
    /// historical files quickly. Priced using the provided pricing table.
    static func scanHourly(for day: String, rootDirectory: URL, pricing: PricingTable) -> [HourlySlice] {
        var byHour: [Int: HourlySlice] = [:]
        for h in 0..<24 { byHour[h] = HourlySlice(hour: h) }

        let fm = FileManager.default
        guard let dayStart = DayBucket.date(fromDay: day) else { return Array(byHour.values).sorted { $0.hour < $1.hour } }
        guard let enumerator = fm.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return Array(byHour.values).sorted { $0.hour < $1.hour } }

        var seen = Set<String>()

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod = modDate, mod < dayStart { continue }

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let data = handle.readDataToEndOfFile()

            for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      let usageDict = msg["usage"] as? [String: Any],
                      let id = msg["id"] as? String,
                      let ts = obj["timestamp"] as? String,
                      let recordDay = DayBucket.localDay(fromISO: ts),
                      recordDay == day,
                      !seen.contains(id)
                else { continue }

                seen.insert(id)
                let rawModel = (msg["model"] as? String) ?? "unknown"
                let family = ModelNormalizer.family(for: rawModel)
                let usage = parseUsage(usageDict)
                let cost = pricing.cost(of: usage, family: family, rawModel: rawModel)
                guard cost > 0 else { continue }

                let date = DayBucket.date(fromISO: ts)
                let hour = date.map { Calendar.current.component(.hour, from: $0) } ?? 0
                byHour[hour]?.cost += cost
                byHour[hour]?.perModel[family, default: 0] += cost
            }
        }

        return Array(byHour.values).sorted { $0.hour < $1.hour }
    }

    static func parseUsage(_ u: [String: Any]) -> TokenUsage {
        func intVal(_ key: String, in dict: [String: Any]) -> Int {
            if let n = dict[key] as? Int { return n }
            if let n = dict[key] as? Double { return Int(n) }
            if let n = dict[key] as? NSNumber { return n.intValue }
            return 0
        }

        let input = intVal("input_tokens", in: u)
        let output = intVal("output_tokens", in: u)
        let cacheRead = intVal("cache_read_input_tokens", in: u)
        let cacheCreationTotal = intVal("cache_creation_input_tokens", in: u)

        var write5m = cacheCreationTotal
        var write1h = 0
        if let breakdown = u["cache_creation"] as? [String: Any] {
            let b5 = intVal("ephemeral_5m_input_tokens", in: breakdown)
            let b1 = intVal("ephemeral_1h_input_tokens", in: breakdown)
            if b5 + b1 > 0 {
                write5m = b5
                write1h = b1
            }
        }

        return TokenUsage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h
        )
    }
}
