import Foundation
import XRCore

/// The wearer's personal head-tracking model: trained on the Mac from their guided sessions, kept
/// per headset, and used only if it measured clearly steadier than the shipped model.
enum PersonalModel {
    struct Saved: Codable {
        var version = 1
        var still: [Float]            // horizons × 39 × 3 (radians)
        var net: HeadPredictor.Net
        var trainedAt: Date
        var minutes: Double
        var shippedMoving: Float, personalMoving: Float
        var shippedStill: Float, personalStill: Float
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XRealDesk", isDirectory: true)
    }

    static func url(serial: String) -> URL { directory.appendingPathComponent("personal-\(serial).json") }

    /// Recorded guided sessions (newest last).
    static func sessions() -> [URL] {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/XRealDesk", isDirectory: true)
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("calibration-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return dirs.compactMap { d in
            let imu = d.appendingPathComponent("imu.csv")
            return FileManager.default.fileExists(atPath: d.appendingPathComponent("labels.csv").path)
                && FileManager.default.fileExists(atPath: imu.path) ? imu : nil
        }
    }

    static func load(serial: String) -> Saved? {
        guard let data = try? Data(contentsOf: url(serial: serial)),
              let s = try? JSONDecoder().decode(Saved.self, from: data), s.version == 1 else { return nil }
        return s
    }

    static func model(_ s: Saved) -> HeadPredictor.Personal? {
        let nf = HeadPredictor.featureCount, nh = HeadPredictor.horizonsMs.count
        guard s.still.count == nh * nf * 3 else { return nil }
        let still: [[SIMD3<Float>]] = (0..<nh).map { h in (0..<nf).map { i in
            let k = (h * nf + i) * 3; return SIMD3(s.still[k], s.still[k + 1], s.still[k + 2]) } }
        let m = HeadPredictor.Personal(still: still, net: s.net)
        return m.isUsable ? m : nil
    }

    static func save(_ r: PersonalTrainer.Result, serial: String) {
        let s = Saved(still: r.model.still.flatMap { $0.flatMap { [$0.x, $0.y, $0.z] } }, net: r.model.net, trainedAt: Date(),
                      minutes: r.minutes, shippedMoving: r.shipped.moving, personalMoving: r.personal.moving,
                      shippedStill: r.shipped.still, personalStill: r.personal.still)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url(serial: serial), options: .atomic) }
    }

    static func remove(serial: String) { try? FileManager.default.removeItem(at: url(serial: serial)) }

    /// One line for Settings.
    static func status(_ s: Saved?, sessions: Int) -> String {
        guard let s else {
            return sessions == 0 ? "Using the default tracking model. Record a session to train your own."
                : "Using the default tracking model. \(sessions) recorded session\(sessions == 1 ? "" : "s") ready for training."
        }
        let gain = (1 - s.personalMoving / max(s.shippedMoving, 1e-6)) * 100
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        return String(format: "Using your own tracking model (trained %@ on %.0f min): %.0f%% steadier while moving than the default.",
                      df.string(from: s.trainedAt), s.minutes, gain)
    }
}
