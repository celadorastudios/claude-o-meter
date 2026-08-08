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

    /// Applies `shouldReRegister` and returns whether a re-registration was performed.
    @discardableResult
    func reconcileAfterMove(intendedEnabled: Bool,
                            lastBundlePath: String,
                            currentBundlePath: String = Bundle.main.bundleURL.path) -> Bool {
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
