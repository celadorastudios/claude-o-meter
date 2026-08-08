import Foundation
import ServiceManagement

final class LoginItemManager {
    static let shared = LoginItemManager()
    private init() {}

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLog.shared.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)", category: "app")
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Migration across a bundle move

    /// Whether the login-item registration has to be recreated for the bundle we are
    /// running from now.
    ///
    /// `SMAppService.mainApp` registers the *running* bundle, so a registration does not
    /// follow the app when it changes location. Moving from `/Applications` to
    /// `~/Applications` (the path anyone stranded by the old hardcoded-destination
    /// updater takes when they reinstall) leaves the old registration dangling and the
    /// new location unregistered, and the app silently stops launching at login.
    ///
    /// Deliberately gated on the path having *changed*. Re-registering whenever intent
    /// says on but the system says off would override someone who switched it off in
    /// System Settings, making the app impossible to disable there. A move is the only
    /// case where the system's "off" is an accident rather than a choice.
    ///
    /// Pure and static so the whole decision table is testable without touching
    /// ServiceManagement.
    static func shouldReRegister(intendedEnabled: Bool,
                                 isCurrentlyEnabled: Bool,
                                 lastBundlePath: String,
                                 currentBundlePath: String) -> Bool {
        guard intendedEnabled, !isCurrentlyEnabled else { return false }
        // No recorded path means this is the first launch that tracks one; there is no
        // move to migrate and re-registering here would be guesswork.
        guard !lastBundlePath.isEmpty else { return false }
        return lastBundlePath != currentBundlePath
    }

    /// Whether this bundle location is one worth tracking and registering.
    ///
    /// Under `swift run` the main bundle is a build directory rather than a `.app`.
    /// `SMAppService` is meaningless there, and recording that path would overwrite the
    /// real install location, making the next genuine launch look like a move (and
    /// masking a real one). Same guard, for the same reason, as
    /// `UpdateInstaller.installDestination`.
    static func isRegistrableBundle(_ bundleURL: URL) -> Bool {
        bundleURL.pathExtension == "app"
    }

    /// The form of a bundle path used for storage and comparison.
    ///
    /// The whole mechanism turns on exact string equality, so both sides have to be
    /// normalised the same way. Without this, symlinked ancestors (`/var` resolving to
    /// `/private/var` is the classic macOS case) or a stray trailing slash read as a move
    /// that never happened, and could equally mask a real one.
    static func normalizedPath(_ bundleURL: URL) -> String {
        bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether the new location may be committed to storage yet.
    ///
    /// Recording the path is what tells the next launch "this move is already handled",
    /// so it must not happen until the system actually agrees with the intent. An
    /// ad-hoc-signed app frequently lands on `.requiresApproval` rather than `.enabled`
    /// after `register()`, and `setEnabled` swallows a thrown error, so "we asked" is not
    /// evidence of success. Committing regardless would make a single failed attempt
    /// permanent: the path would match forever after, and `shouldReRegister` could never
    /// fire again for this location.
    static func shouldRecordNewPath(intendedEnabled: Bool, resultingIsEnabled: Bool) -> Bool {
        // Nothing to achieve when the user does not want it on.
        guard intendedEnabled else { return true }
        // Otherwise only once the system agrees, so an unsuccessful attempt is retried.
        return resultingIsEnabled
    }

    /// Applies `shouldReRegister` and returns whether a re-registration was attempted.
    ///
    /// A `true` result means the attempt was made, not that it succeeded: `setEnabled`
    /// cannot report failure. Callers must re-read `isEnabled` to learn the outcome.
    @discardableResult
    func reconcileAfterMove(intendedEnabled: Bool,
                            lastBundlePath: String,
                            currentBundlePath: String) -> Bool {
        guard Self.shouldReRegister(intendedEnabled: intendedEnabled,
                                    isCurrentlyEnabled: isEnabled,
                                    lastBundlePath: lastBundlePath,
                                    currentBundlePath: currentBundlePath) else {
            return false
        }

        AppLog.shared.info("app moved from \(lastBundlePath) to \(currentBundlePath); restoring launch-at-login",
                           category: "app")
        setEnabled(true)
        return true
    }
}
