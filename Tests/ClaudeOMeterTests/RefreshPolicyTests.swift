import XCTest
@testable import ClaudeOMeter

/// The popover only refreshed on its own 60s timer, so opening it on the Daily view could
/// show data up to a full period stale — worse under App Nap, since the app has no visible
/// window while the popover is closed. `shouldRefreshOnPresentation` is the pure decision
/// behind "refresh when the popover appears," testable without constructing a `UsageStore`
/// (its `init()` touches real disk state, a timer, and `SMAppService`).
final class RefreshPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - The case this exists for

    func testRefreshesWhenTheDataIsOlderThanTheThrottle() {
        XCTAssertTrue(RefreshPolicy.shouldRefreshOnPresentation(
            lastRefresh: now.addingTimeInterval(-60), now: now, isRefreshing: false))
    }

    // MARK: - Cases that must NOT act

    func testDoesNotRescanWhenTheDataIsAlreadyFresh() {
        XCTAssertFalse(RefreshPolicy.shouldRefreshOnPresentation(
            lastRefresh: now.addingTimeInterval(-0.5), now: now, isRefreshing: false,
            minimumInterval: 2),
            "rapid open/close/open must not stack disk walks")
    }

    func testDoesNotStackAScanOnTopOfOneAlreadyInFlight() {
        XCTAssertFalse(RefreshPolicy.shouldRefreshOnPresentation(
            lastRefresh: nil, now: now, isRefreshing: true))
    }

    // MARK: - Edge cases

    func testRefreshesWhenNothingHasEverBeenScanned() {
        XCTAssertTrue(RefreshPolicy.shouldRefreshOnPresentation(
            lastRefresh: nil, now: now, isRefreshing: false))
    }

    func testTheThrottleBoundaryIsInclusive() {
        XCTAssertTrue(RefreshPolicy.shouldRefreshOnPresentation(
            lastRefresh: now.addingTimeInterval(-2), now: now, isRefreshing: false,
            minimumInterval: 2))
    }

    /// A naive `now.timeIntervalSince(last) >= interval` reads a future timestamp as fresh,
    /// so a clock correction (DST, NTP) would wedge presentation refreshes until real time
    /// caught back up. Any out-of-range delta, negative included, counts as stale.
    func testAClockThatMovedBackwardsStillRefreshes() {
        XCTAssertTrue(RefreshPolicy.shouldRefreshOnPresentation(
            lastRefresh: now.addingTimeInterval(3600), now: now, isRefreshing: false))
    }
}
