import Foundation
import os

/// Logs to the unified log and to ~/Library/Logs/XRealDesk.log (for "send me your log" debugging).
enum Log {
    private static let logger = Logger(subsystem: "com.xrealdesk.app", category: "app")
    private static let queue = DispatchQueue(label: "XRealDesk.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("XRealDesk.log")
    }()
    private static var handle: FileHandle? = {
        let url = fileURL
        // Keep the log small: start fresh if it grew past 2 MB.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if ProcessInfo.processInfo.environment["XRD_STDOUT"] != nil { print(line, terminator: "") }
        queue.async { handle?.write(line.data(using: .utf8)!) }
    }

    static func error(_ message: String) { info("ERROR: \(message)") }
}
