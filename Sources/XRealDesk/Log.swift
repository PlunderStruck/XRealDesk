import Foundation
import os

/// Logs to the unified log (kept in memory by macOS, not on disk) and, only when the diagnostic log
/// is switched on in Settings, to ~/Library/Logs/XRealDesk.log. Errors are always written: they're
/// rare and they're what you need when something breaks.
enum Log {
    private static let diskLock = OSAllocatedUnfairLock(initialState: false)
    /// Full diagnostic log on disk (Settings → General). Off by default.
    static var diagnostics: Bool {
        get { diskLock.withLock { $0 } }
        set { diskLock.withLock { $0 = newValue } }
    }

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

    private static var written = 0                               // log queue only
    private static var repeats: [String: (count: Int, since: Date)] = [:]   // log queue only

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard diagnostics else { return }
        write(message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR: \(message)")
    }

    private static func write(_ message: String) {
        let now = Date()
        queue.async {
            // The same line again within a minute (a device rescanning every few seconds…) is counted,
            // not written; the count shows up with the next one that is written.
            var suffix = ""
            if let r = repeats[message], now.timeIntervalSince(r.since) < 60 {
                repeats[message] = (r.count + 1, r.since)
                return
            } else if let r = repeats[message], r.count > 0 {
                suffix = " (repeated \(r.count)× in the last minute)"
            }
            if repeats.count > 500 { repeats.removeAll() }
            repeats[message] = (0, now)
            let line = "\(formatter.string(from: now)) \(message)\(suffix)\n"
            if ProcessInfo.processInfo.environment["XRD_STDOUT"] != nil { print(line, terminator: "") }
            written += line.utf8.count
            if written > 4_000_000 { rotate() }
            // write(contentsOf:) throws instead of raising an Objective-C exception (disk full, I/O error).
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    /// Keeps the log bounded during long sessions: the current file becomes XRealDesk.old.log.
    private static func rotate() {
        try? handle?.close()
        let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        written = 0
    }

}
