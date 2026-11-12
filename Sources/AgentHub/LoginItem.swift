import Foundation
import Observation
import ServiceManagement

/// Starting AgentHub at login, so the notch panel is there after a restart.
@MainActor
@Observable
final class LoginItem {
    private(set) var enabled = false
    var message: String?

    private static let offeredKey = "loginItemOffered"

    /// Only the installed copy registers itself: a login item pointing into a build folder breaks
    /// as soon as that folder is cleaned.
    var isInstalledCopy: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }

    init() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    /// On the first launch of the installed app, turn it on once. Turning it off later sticks.
    func enableOnFirstInstalledLaunch() {
        let defaults = UserDefaults.standard
        guard isInstalledCopy, !defaults.bool(forKey: Self.offeredKey) else { return }
        defaults.set(true, forKey: Self.offeredKey)
        set(true)
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            message = "Login item: \(error.localizedDescription)"
        }
        enabled = SMAppService.mainApp.status == .enabled
        // macOS may ask for approval in System Settings › General › Login Items first.
        if on && SMAppService.mainApp.status == .requiresApproval {
            message = "Allow AgentHub in System Settings › General › Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
