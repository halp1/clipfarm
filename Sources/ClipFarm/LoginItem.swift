import Foundation
import ServiceManagement

/// The open at login toggle, backed by SMAppService.
///
/// Registration only works for an app running from /Applications with a stable bundle
/// identifier, so a debug build launched from .build will report a failure here.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            Log.error("Could not change the open at login setting: \(error.localizedDescription)")
            return false
        }
    }
}
