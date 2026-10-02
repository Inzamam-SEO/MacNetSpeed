import Foundation
import ServiceManagement

enum LoginItem {
    static let preferenceKey = "launchAtLoginEnabled"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turns the login item on until the user switches it off.
    /// A failed registration (the app is not in Applications yet) is retried next launch.
    static func syncPreferredState() {
        let defaults = UserDefaults.standard
        let wantsLogin = defaults.object(forKey: preferenceKey) as? Bool ?? true
        guard wantsLogin else { return }
        try? setEnabled(true)
        if isEnabled {
            defaults.set(true, forKey: preferenceKey)
        }
    }

    static var statusMessage: String? {
        switch SMAppService.mainApp.status {
        case .enabled:
            return nil
        case .requiresApproval:
            return "Allow MacNetSpeed in System Settings → General → Login Items."
        case .notFound, .notRegistered:
            return nil
        @unknown default:
            return nil
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
