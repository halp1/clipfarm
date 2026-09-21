import Foundation
import OSLog

/// Logging goes through os.Logger, so `log stream --predicate 'subsystem == "dev.haelp.clipfarm"'`
/// shows what the app is doing.
enum Log {
    private static let logger = Logger(subsystem: "dev.haelp.clipfarm", category: "app")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
