import XCTest
@testable import ClaudeOMeter

final class ProjectsRootTests: XCTestCase {

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    // MARK: - Default (no override, no env)

    func testDefaultRootWhenNothingSet() {
        let url = ProjectsRoot.resolve(override: nil, environment: [:])
        XCTAssertEqual(url.path, "\(home)/.claude/projects")
    }

    // MARK: - Env var

    func testEnvVarUsedWhenNoOverride() {
        let env = ["CLAUDE_CONFIG_DIR": "/tmp/cfg"]
        let url = ProjectsRoot.resolve(override: nil, environment: env)
        XCTAssertEqual(url.path, "/tmp/cfg/projects")
    }

    func testEmptyEnvVarFallsThroughToDefault() {
        let url = ProjectsRoot.resolve(override: nil, environment: ["CLAUDE_CONFIG_DIR": "   "])
        XCTAssertEqual(url.path, "\(home)/.claude/projects")
    }

    // MARK: - Override precedence

    func testOverrideBeatsEnvVar() {
        let env = ["CLAUDE_CONFIG_DIR": "/tmp/cfg"]
        let url = ProjectsRoot.resolve(override: "/tmp/override", environment: env)
        XCTAssertEqual(url.path, "/tmp/override/projects")
    }

    func testEmptyOverrideFallsThroughToEnv() {
        let env = ["CLAUDE_CONFIG_DIR": "/tmp/cfg"]
        let url = ProjectsRoot.resolve(override: "", environment: env)
        XCTAssertEqual(url.path, "/tmp/cfg/projects")
    }

    func testWhitespaceOverrideFallsThroughToDefault() {
        let url = ProjectsRoot.resolve(override: "  \n ", environment: [:])
        XCTAssertEqual(url.path, "\(home)/.claude/projects")
    }

    func testWhitespaceOverrideFallsThroughToEnv() {
        let env = ["CLAUDE_CONFIG_DIR": "/tmp/cfg"]
        let url = ProjectsRoot.resolve(override: "  \n ", environment: env)
        XCTAssertEqual(url.path, "/tmp/cfg/projects")
    }

    // MARK: - Tilde expansion

    func testOverrideExpandsTilde() {
        let url = ProjectsRoot.resolve(override: "~/.claude/cpm/profiles/personal", environment: [:])
        XCTAssertEqual(url.path, "\(home)/.claude/cpm/profiles/personal/projects")
    }

    func testOverrideTrimsSurroundingWhitespace() {
        let url = ProjectsRoot.resolve(override: "  /tmp/cfg  ", environment: [:])
        XCTAssertEqual(url.path, "/tmp/cfg/projects")
    }

    // MARK: - projects/ suffix is always appended

    func testProjectsSuffixAppendedToOverride() {
        let url = ProjectsRoot.resolve(override: "/tmp/cfg", environment: [:])
        XCTAssertEqual(url.lastPathComponent, "projects")
    }
}
