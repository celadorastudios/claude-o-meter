import Foundation

/// Whether the popover appearing on screen should trigger a scan.
///
/// The 60s timer alone left the Daily view showing data up to a full period stale on open,
/// worse under App Nap since the app has no visible window while the popover is closed.
/// This is the pure decision behind "refresh when the popover appears" — kept out of
/// `UsageStore` so it is testable without constructing one (its `init()` touches real disk
/// state, a timer, and `SMAppService`).
enum RefreshPolicy {
    /// Presentation refreshes are throttled to this interval so a rapid open/close/open
    /// doesn't stack redundant disk walks.
    static let presentationThrottle: TimeInterval = 2

    static func shouldRefreshOnPresentation(lastRefresh: Date?,
                                            now: Date,
                                            isRefreshing: Bool,
                                            minimumInterval: TimeInterval = presentationThrottle) -> Bool {
        guard !isRefreshing else { return false }
        guard let lastRefresh else { return true }
        let elapsed = now.timeIntervalSince(lastRefresh)
        // Any out-of-range delta, negative included, counts as stale — a naive `>=` check
        // alone would read a future `lastRefresh` (a clock correction) as fresh forever.
        return !(0..<minimumInterval).contains(elapsed)
    }
}
