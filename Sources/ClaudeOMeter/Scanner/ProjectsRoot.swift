import Foundation

/// Resolves which `projects/` directory the scanner should read.
///
/// Claude Code writes transcripts under `$CLAUDE_CONFIG_DIR/projects` (default `~/.claude/projects`).
/// Users running isolated profiles (a non-default `CLAUDE_CONFIG_DIR`, e.g. via cpm) otherwise see
/// only their default profile's usage. This resolver picks a single root by precedence:
///
///   1. An explicit settings override (a *config dir*; we append `/projects`), when non-empty.
///   2. `$CLAUDE_CONFIG_DIR/projects`, when the env var is set and non-empty.
///   3. `~/.claude/projects` (the built-in default).
///
/// Only one root is scanned at a time, so per-project attribution never collides across profiles.
///
/// Note on the env-var default: GUI apps launched as login items do not inherit shell-exported
/// environment variables, so precedence 2 is best-effort. The settings override (precedence 1) is
/// the reliable mechanism; the UI surfaces the resolved path so the live root is never a mystery.
enum ProjectsRoot {
    /// The built-in default when no override or env var applies.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Resolve the effective `projects/` directory.
    ///
    /// - Parameters:
    ///   - override: A user-configured *config directory* (not the `projects/` dir itself). When
    ///     non-empty after trimming, `/projects` is appended. A leading `~` is expanded to the home
    ///     directory. Pass `nil` or an empty/whitespace string to fall through to the env var / default.
    ///   - environment: Process environment, injectable for testing. Defaults to the real environment.
    static func resolve(
        override: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let dir = configDir(from: override) {
            return dir.appendingPathComponent("projects", isDirectory: true)
        }
        if let envValue = environment["CLAUDE_CONFIG_DIR"],
           let dir = configDir(from: envValue) {
            return dir.appendingPathComponent("projects", isDirectory: true)
        }
        return defaultRoot
    }

    /// Turn a raw config-dir string into a URL, or nil when blank. Expands a leading `~`.
    private static func configDir(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
