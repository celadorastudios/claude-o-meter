import XCTest
@testable import ClaudeOMeter

/// Executes the real swap script `UpdateInstaller` generates, against fixture bundles in a
/// sandbox. `open` and `xattr` are stubbed on PATH so nothing launches during the run and
/// the script's own logic is what gets exercised.
final class UpdateInstallerTests: XCTestCase {

    private var sandbox: URL!
    private var stubBin: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeometer-installer-\(UUID().uuidString)")
        stubBin = sandbox.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: stubBin, withIntermediateDirectories: true)

        for tool in ["open", "xattr"] {
            let stub = stubBin.appendingPathComponent(tool)
            try "#!/bin/bash\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        try super.tearDownWithError()
    }

    // MARK: - Destination resolution

    // The bug this guards: install.sh installs to ~/Applications, but the updater used to
    // hardcode /Applications, so updates landed in a copy the user never launched.
    func testDestinationFollowsTheRunningBundle() {
        let home = URL(fileURLWithPath: "/Users/me/Applications/ClaudeOMeter.app")
        XCTAssertEqual(UpdateInstaller.installDestination(bundleURL: home),
                       "/Users/me/Applications/ClaudeOMeter.app")

        let system = URL(fileURLWithPath: "/Applications/ClaudeOMeter.app")
        XCTAssertEqual(UpdateInstaller.installDestination(bundleURL: system),
                       "/Applications/ClaudeOMeter.app")
    }

    // Under `swift run` the main bundle is a build directory, which must never be swapped.
    func testDestinationFallsBackWhenNotAnAppBundle() {
        let buildDir = URL(fileURLWithPath: "/Users/me/proj/.build/release")
        XCTAssertEqual(UpdateInstaller.installDestination(bundleURL: buildDir),
                       "/Applications/ClaudeOMeter.app")
    }

    // MARK: - Swap behaviour

    func testSwapReplacesInstalledAppAndCleansUp() throws {
        let f = try makeFixture(installedMarker: "old", stagedMarker: "new")

        let result = try runHelper(f)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try marker(in: f.dest), "new", "the new bundle should be installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dest.path + ".old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dest.path + ".new"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.unpackDir.path),
                       "unpacked update should be cleaned up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.zip.path),
                       "downloaded zip should be cleaned up")
    }

    func testSwapInstallsWhenNothingIsAlreadyThere() throws {
        let f = try makeFixture(installedMarker: nil, stagedMarker: "new")

        let result = try runHelper(f)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try marker(in: f.dest), "new")
    }

    // The regression this guards: the old script ran `rm -rf` on the install before copying,
    // so a copy that failed left the user with no app at all.
    func testFailedCopyLeavesTheExistingInstallIntact() throws {
        let f = try makeFixture(installedMarker: "old", stagedMarker: "new")
        try FileManager.default.removeItem(at: f.newApp)   // source disappears mid-update

        let result = try runHelper(f)

        XCTAssertNotEqual(result.exitCode, 0, "a missing source should fail loudly")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.dest.path),
                      "the working install must survive a failed update")
        XCTAssertEqual(try marker(in: f.dest), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dest.path + ".new"),
                       "staging directory should not be left behind")
    }

    // MARK: - Destructive-operation guards

    // Every recursive delete in the script is derived from an interpolated path, so a
    // malformed one must stop the script before anything is removed rather than expanding
    // into a delete of "/" or a top-level directory.
    func testScriptRefusesUnsafeDestinations() throws {
        let unsafe = [
            "",
            "/",
            "/Applications",                                // one level deep, not a bundle
            "/Users/me/../../ClaudeOMeter.app",             // traversal
            "relative/ClaudeOMeter.app",                    // not absolute
        ]

        for dest in unsafe {
            let f = try makeFixture(installedMarker: "old", stagedMarker: "new")
            let result = try runScript(destPath: dest, fixture: f)

            XCTAssertNotEqual(result.exitCode, 0, "should refuse destination \"\(dest)\"")
            XCTAssertTrue(result.output.contains("unsafe destination"),
                          "should say why it refused \"\(dest)\", got: \(result.output)")
            // Nothing may have been touched on the way to refusing.
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.unpackDir.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.zip.path))
            try? FileManager.default.removeItem(at: f.unpackDir)
            try? FileManager.default.removeItem(at: f.zip)
        }
    }

    func testSafeRmSkipsShallowAndTraversalPaths() throws {
        // Drive the script's own safe_rm through a destination whose siblings would be
        // dangerous, proving the helper never recurses into a protected path.
        let script = UpdateInstaller.helperScript(destPath: "/Applications/ClaudeOMeter.app",
                                                  newAppPath: "/tmp/u/ClaudeOMeter.app",
                                                  destDir: "/",
                                                  zipPath: "")
        XCTAssertTrue(script.contains("safe_rm"), "deletes must go through the guard")
        XCTAssertFalse(script.contains("rm -rf \"$STAGE\" \"$BACKUP\""),
                       "no unguarded recursive delete should remain")
    }

    func testScriptCarriesNoHardcodedApplicationsPath() {
        let script = UpdateInstaller.helperScript(destPath: "/Users/me/Applications/ClaudeOMeter.app",
                                                  newAppPath: "/tmp/u/ClaudeOMeter.app",
                                                  destDir: "/tmp/u",
                                                  zipPath: "/tmp/u.zip")
        XCTAssertFalse(script.contains("\"/Applications/ClaudeOMeter.app\""),
                       "destination must come from the running bundle, not a literal")
        XCTAssertTrue(script.contains("/Users/me/Applications/ClaudeOMeter.app"))
    }

    // MARK: - Fixture helpers

    private struct Fixture {
        let dest: URL
        let newApp: URL
        let unpackDir: URL
        let zip: URL
        let scriptPath: URL
    }

    private func makeFixture(installedMarker: String?, stagedMarker: String) throws -> Fixture {
        let fm = FileManager.default
        let installRoot = sandbox.appendingPathComponent("Applications")
        let unpackDir = sandbox.appendingPathComponent("unpacked")
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: unpackDir, withIntermediateDirectories: true)

        let dest = installRoot.appendingPathComponent("ClaudeOMeter.app")
        if let installedMarker {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try installedMarker.write(to: dest.appendingPathComponent("marker"),
                                      atomically: true, encoding: .utf8)
        }

        let newApp = unpackDir.appendingPathComponent("ClaudeOMeter.app")
        try fm.createDirectory(at: newApp, withIntermediateDirectories: true)
        try stagedMarker.write(to: newApp.appendingPathComponent("marker"),
                               atomically: true, encoding: .utf8)

        let zip = sandbox.appendingPathComponent("update.zip")
        try Data("zip".utf8).write(to: zip)

        return Fixture(dest: dest,
                       newApp: newApp,
                       unpackDir: unpackDir,
                       zip: zip,
                       scriptPath: sandbox.appendingPathComponent("update.sh"))
    }

    private func marker(in app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8)
    }

    private func runHelper(_ f: Fixture) throws -> (exitCode: Int32, output: String) {
        try runScript(destPath: f.dest.path, fixture: f)
    }

    @discardableResult
    private func runScript(destPath: String, fixture f: Fixture) throws -> (exitCode: Int32, output: String) {
        let script = UpdateInstaller.helperScript(destPath: destPath,
                                                  newAppPath: f.newApp.path,
                                                  destDir: f.unpackDir.path,
                                                  zipPath: f.zip.path)
        try script.write(to: f.scriptPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [f.scriptPath.path]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = stubBin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CLAUDEOMETER_UPDATE_DELAY"] = "0"   // no reason to wait in tests
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
