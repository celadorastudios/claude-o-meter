import XCTest
@testable import ClaudeOMeter

/// The launch-at-login setting has to survive the app changing location.
///
/// `SMAppService` registers the *running* bundle, so a registration does not follow the
/// app when it moves. Anyone stranded by the old hardcoded-`/Applications` updater lands
/// in a different directory when they reinstall, which silently turned their setting off
/// and left a dangling login item behind.
///
/// `shouldReRegister` is pure, so the whole decision table is testable here without
/// touching ServiceManagement or mutating the machine's real login items.
final class LoginItemMigrationTests: XCTestCase {

    private let old = "/Applications/ClaudeOMeter.app"
    private let new = "/Users/me/Applications/ClaudeOMeter.app"

    // MARK: - The case this exists for

    func testReRegistersWhenTheBundleMovedAndTheUserWantedItOn() {
        XCTAssertTrue(LoginItemManager.shouldReRegister(intendedEnabled: true,
                                                        isCurrentlyEnabled: false,
                                                        lastBundlePath: old,
                                                        currentBundlePath: new))
    }

    // MARK: - Cases that must NOT act

    /// The important negative. If intent-on plus system-off were enough on its own, the
    /// app would re-enable itself every launch and could never be switched off in
    /// System Settings.
    func testDoesNotReRegisterWhenTheUserTurnedItOffInSystemSettings() {
        XCTAssertFalse(LoginItemManager.shouldReRegister(intendedEnabled: true,
                                                         isCurrentlyEnabled: false,
                                                         lastBundlePath: new,
                                                         currentBundlePath: new),
                       "same path means the system's 'off' was a deliberate choice")
    }

    /// No recorded path means nothing is known about a previous location, so acting would
    /// be guesswork rather than migration.
    func testDoesNotReRegisterOnFirstRun() {
        XCTAssertFalse(LoginItemManager.shouldReRegister(intendedEnabled: true,
                                                         isCurrentlyEnabled: false,
                                                         lastBundlePath: "",
                                                         currentBundlePath: new))
    }

    func testDoesNotReRegisterWhenTheUserNeverWantedIt() {
        XCTAssertFalse(LoginItemManager.shouldReRegister(intendedEnabled: false,
                                                         isCurrentlyEnabled: false,
                                                         lastBundlePath: old,
                                                         currentBundlePath: new))
    }

    /// A move that somehow kept its registration needs no repair.
    func testDoesNotReRegisterWhenAlreadyEnabled() {
        XCTAssertFalse(LoginItemManager.shouldReRegister(intendedEnabled: true,
                                                         isCurrentlyEnabled: true,
                                                         lastBundlePath: old,
                                                         currentBundlePath: new))
    }

    /// An ordinary in-place upgrade: the swap script replaces the bundle at the same path,
    /// so the registration survives and nothing should be touched.
    func testSamePathUpgradeIsNotTreatedAsAMove() {
        for enabled in [true, false] {
            XCTAssertFalse(LoginItemManager.shouldReRegister(intendedEnabled: true,
                                                             isCurrentlyEnabled: enabled,
                                                             lastBundlePath: new,
                                                             currentBundlePath: new))
        }
    }

    /// The real migration direction, spelled out: install.sh installs to ~/Applications,
    /// while the old updater wrote to /Applications.
    func testMigratesInBothDirectionsBetweenTheTwoInstallLocations() {
        XCTAssertTrue(LoginItemManager.shouldReRegister(intendedEnabled: true,
                                                        isCurrentlyEnabled: false,
                                                        lastBundlePath: old,
                                                        currentBundlePath: new))
        XCTAssertTrue(LoginItemManager.shouldReRegister(intendedEnabled: true,
                                                        isCurrentlyEnabled: false,
                                                        lastBundlePath: new,
                                                        currentBundlePath: old))
    }

    // MARK: - Which bundles are worth tracking

    /// Under `swift run` the main bundle is a build directory. Recording that path would
    /// overwrite the real install location and make the next genuine launch look like a
    /// move, so dev runs must be ignored entirely.
    func testOnlyAppBundlesAreTracked() {
        XCTAssertTrue(LoginItemManager.isRegistrableBundle(URL(fileURLWithPath: new)))
        XCTAssertTrue(LoginItemManager.isRegistrableBundle(URL(fileURLWithPath: old)))

        for dev in ["/Users/me/proj/.build/arm64-apple-macosx/debug",
                    "/Users/me/proj/.build/release",
                    "/usr/local/bin"] {
            XCTAssertFalse(LoginItemManager.isRegistrableBundle(URL(fileURLWithPath: dev)),
                           "\(dev) is not an app bundle and must not be tracked")
        }
    }

    // MARK: - Persistence of the intent

    /// The setting is only restorable if it is actually written down, and it has to
    /// survive a round trip through the existing snapshot format.
    func testIntentAndPathSurviveASnapshotRoundTrip() throws {
        var snapshot = Persistence.Snapshot()
        snapshot.launchAtLogin = true
        snapshot.lastBundlePath = new

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(Persistence.Snapshot.self, from: data)

        XCTAssertTrue(decoded.launchAtLogin)
        XCTAssertEqual(decoded.lastBundlePath, new)
    }

    /// A state.json written by 0.12.0 or earlier has neither field. It must still decode,
    /// rather than throwing and wiping every other setting the user has.
    func testSnapshotFromAnEarlierVersionStillDecodes() throws {
        let legacy = Data(#"{"aggregates":{},"dataVersion":3,"pricingVersion":7}"#.utf8)

        let decoded = try JSONDecoder().decode(Persistence.Snapshot.self, from: legacy)

        XCTAssertFalse(decoded.launchAtLogin, "absent intent defaults to off")
        XCTAssertEqual(decoded.lastBundlePath, "", "absent path must read as first run")
        XCTAssertEqual(decoded.dataVersion, 3, "existing fields must be preserved")
        XCTAssertEqual(decoded.pricingVersion, 7)
    }

    /// An empty recorded path combined with an absent intent is the first-run shape, and
    /// it must never trigger a registration on its own.
    func testFreshSnapshotIsInert() {
        let snapshot = Persistence.Snapshot()
        XCTAssertFalse(LoginItemManager.shouldReRegister(intendedEnabled: snapshot.launchAtLogin,
                                                         isCurrentlyEnabled: false,
                                                         lastBundlePath: snapshot.lastBundlePath,
                                                         currentBundlePath: new))
    }
}
