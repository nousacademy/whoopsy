import Foundation
import os.log

/// Privacy-safe unified logging facility for Whoopsy.
public enum AppLogger {
    private static let subsystem = "org.whoopsy.app"

    public static let ble = Logger(subsystem: subsystem, category: "BLE")
    public static let decoder = Logger(subsystem: subsystem, category: "Decoder")
    public static let database = Logger(subsystem: subsystem, category: "Database")
    public static let algorithms = Logger(subsystem: subsystem, category: "Algorithms")
    public static let ui = Logger(subsystem: subsystem, category: "UI")
}
