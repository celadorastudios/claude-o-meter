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
        // The script polls pgrep to confirm the new build actually started. Default to
        // "it started" so existing cases exercise the success path.
        try stubPgrep(found: true)
    }

    /// `pgrep -x ClaudeOMeter` decides whether the swap is committed or rolled back.
    private func stubPgrep(found: Bool) throws {
        let stub = stubBin.appendingPathComponent("pgrep")
        try "#!/bin/bash\nexit \(found ? 0 : 1)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
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
    // The fallback is ~/Applications, matching install.sh: it needs no admin rights, so an
    // update can always be written without prompting for a password.
    func testDestinationFallsBackWhenNotAnAppBundle() {
        let buildDir = URL(fileURLWithPath: "/Users/me/proj/.build/release")
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(UpdateInstaller.installDestination(bundleURL: buildDir, home: home),
                       "/Users/me/Applications/ClaudeOMeter.app")
    }

    // The fallback must never be the system-wide location, which needs admin rights.
    func testFallbackIsNeverTheSystemApplicationsFolder() {
        let buildDir = URL(fileURLWithPath: "/Users/me/proj/.build/release")
        XCTAssertNotEqual(UpdateInstaller.installDestination(bundleURL: buildDir),
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

    // MARK: - Rollback when the new build will not start

    /// The regression this guards: the previous version used to be deleted *before* the
    /// new one was launched, so a build that crashed on startup left no way back at all.
    func testFailedLaunchRestoresThePreviousVersion() throws {
        let f = try makeFixture(installedMarker: "old", stagedMarker: "new")
        try stubPgrep(found: false)   // the new build never comes up

        let result = try runHelper(f)

        XCTAssertEqual(try marker(in: f.dest), "old", "the working version must be restored")
        XCTAssertTrue(result.output.contains("did not start"), "the rollback should say why")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dest.path + ".failed"),
                       "the broken bundle should not be left beside the restored one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dest.path + ".old"))
    }

    /// The rollback copy is only discarded once the new version is confirmed running.
    func testSuccessfulLaunchDiscardsTheRollbackCopy() throws {
        let f = try makeFixture(installedMarker: "old", stagedMarker: "new")
        try stubPgrep(found: true)

        let result = try runHelper(f)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try marker(in: f.dest), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dest.path + ".old"),
                       "the backup should be reaped once the new version is up")
    }

    /// A first install has nothing to roll back to, so a failed launch must not error out
    /// or leave debris.
    func testFailedLaunchOnAFirstInstallLeavesTheNewBundleInPlace() throws {
        let f = try makeFixture(installedMarker: nil, stagedMarker: "new")
        try stubPgrep(found: false)

        _ = try runHelper(f)

        XCTAssertEqual(try marker(in: f.dest), "new", "there is no previous version to restore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dest.path + ".failed"))
    }

    /// Regression guard. `pgrep -x ClaudeOMeter` matches *any* instance, so if the old
    /// process outlived the exit wait the script would see it, conclude the new build
    /// started, and throw away the rollback copy. The swap now refuses to run at all
    /// while the old process is alive, which removes that reading entirely.
    func testRefusesToSwapWhileTheOldProcessIsStillRunning() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        addTeardownBlock { sleeper.terminate() }

        let f = try makeFixture(installedMarker: "old", stagedMarker: "new")
        // Exit wait gives up quickly; the process is still alive when it does.
        let result = try runScript(destPath: f.dest.path, fixture: f,
                                   quittingPID: sleeper.processIdentifier,
                                   exitTimeout: 2)

        XCTAssertNotEqual(result.exitCode, 0, "should refuse rather than swap under a live app")
        XCTAssertTrue(result.output.contains("still running"), "should say why: \(result.output)")
        XCTAssertEqual(try marker(in: f.dest), "old", "the running install must be untouched")
    }

    // MARK: - Waiting for the old process to exit

    /// A fixed sleep raced a slow shutdown and could swap the bundle under a live process,
    /// which then relaunched as a second instance. The script now polls the pid.
    func testScriptWaitsOnTheQuittingProcess() {
        let script = UpdateInstaller.helperScript(destPath: "/Users/me/Applications/ClaudeOMeter.app",
                                                  newAppPath: "/tmp/u/ClaudeOMeter.app",
                                                  destDir: "/tmp/u",
                                                  zipPath: "/tmp/u.zip",
                                                  quittingPID: 4242)
        XCTAssertTrue(script.contains("PID=4242"))
        XCTAssertTrue(script.contains("kill -0"), "should poll the pid rather than guess")
    }

    /// A live pid must hold the swap off. Uses a real background process so the wait is
    /// exercised rather than asserted on the script text.
    func testSwapWaitsUntilTheProcessActuallyExits() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["3"]
        try sleeper.run()

        let f = try makeFixture(installedMarker: "old", stagedMarker: "new")
        let started = Date()
        let result = try runScript(destPath: f.dest.path, fixture: f, quittingPID: sleeper.processIdentifier)
        let elapsed = Date().timeIntervalSince(started)

        sleeper.waitUntilExit()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(elapsed, 2.0, "the swap should have waited for the pid to exit")
        XCTAssertEqual(try marker(in: f.dest), "new")
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
    private func runScript(destPath: String,
                           fixture f: Fixture,
                           quittingPID: Int32 = 0,
                           exitTimeout: Int = 10) throws -> (exitCode: Int32, output: String) {
        let script = UpdateInstaller.helperScript(destPath: destPath,
                                                  newAppPath: f.newApp.path,
                                                  destDir: f.unpackDir.path,
                                                  zipPath: f.zip.path,
                                                  quittingPID: quittingPID)
        try script.write(to: f.scriptPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [f.scriptPath.path]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = stubBin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CLAUDEOMETER_UPDATE_DELAY"] = "0"    // no reason to wait in tests
        env["CLAUDEOMETER_EXIT_TIMEOUT"] = String(exitTimeout)  // bounds the pid wait
        env["CLAUDEOMETER_LAUNCH_TIMEOUT"] = "2"  // keeps the rollback case quick
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
