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
        /// Head speeds (°/s) over which this net takes over from the shipped one (nil: all speeds).
        var handover: [Float]? = nil

        /// "27% steadier while moving, 4% less steady when still" (from held-back data).
        var summary: String {
            let moving = (1 - personalMoving / max(shippedMoving, 1e-6)) * 100
            let still = (personalStill / max(shippedStill, 1e-6) - 1) * 100
            let m = String(format: moving >= 0 ? "%.0f%% steadier while moving" : "%.0f%% less steady while moving", abs(moving))
            let s = abs(still) < 1 ? "as steady when still" : String(format: still > 0 ? "%.0f%% less steady when still" : "%.0f%% steadier when still", abs(still))
            return m + ", " + s
        }
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XRealDesk", isDirectory: true)
    }

    static func url(serial: String) -> URL { directory.appendingPathComponent("personal-\(serial).json") }
    /// A trained model that wasn't switched on by itself (better moving, a little less steady still):
    /// kept for a blind comparison until the wearer uses it or trains again.
    static func candidateURL(serial: String) -> URL { directory.appendingPathComponent("personal-\(serial)-candidate.json") }

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

    static func load(serial: String) -> Saved? { read(url(serial: serial)) }
    static func loadCandidate(serial: String) -> Saved? { read(candidateURL(serial: serial)) }

    private static func read(_ url: URL) -> Saved? {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Saved.self, from: data), s.version == 1 else { return nil }
        return s
    }

    static func model(_ s: Saved) -> HeadPredictor.Personal? {
        let nf = HeadPredictor.featureCount, nh = HeadPredictor.horizonsMs.count
        guard s.still.count == nh * nf * 3 else { return nil }
        let still: [[SIMD3<Float>]] = (0..<nh).map { h in (0..<nf).map { i in
            let k = (h * nf + i) * 3; return SIMD3(s.still[k], s.still[k + 1], s.still[k + 2]) } }
        let hv = s.handover.flatMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
        let m = HeadPredictor.Personal(still: still, net: s.net, handover: hv)
        return m.isUsable ? m : nil
    }

    static func save(_ r: PersonalTrainer.Result, serial: String, candidate: Bool = false) {
        let s = Saved(still: r.model.still.flatMap { $0.flatMap { [$0.x, $0.y, $0.z] } }, net: r.model.net, trainedAt: Date(),
                      minutes: r.minutes, shippedMoving: r.shipped.moving, personalMoving: r.personal.moving,
                      shippedStill: r.shipped.still, personalStill: r.personal.still,
                      handover: r.model.handover.map { [$0.x, $0.y] })
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: candidate ? candidateURL(serial: serial) : url(serial: serial), options: .atomic) }
    }

    static func remove(serial: String) { try? FileManager.default.removeItem(at: url(serial: serial)) }
    static func removeCandidate(serial: String) { try? FileManager.default.removeItem(at: candidateURL(serial: serial)) }

    /// The candidate becomes the model in use.
    static func adoptCandidate(serial: String) -> Saved? {
        guard let c = loadCandidate(serial: serial) else { return nil }
        remove(serial: serial)
        try? FileManager.default.moveItem(at: candidateURL(serial: serial), to: url(serial: serial))
        return c
    }

    /// One line for Settings.
    static func status(_ s: Saved?, candidate: Saved? = nil, sessions: Int) -> String {
        if let c = candidate {
            return (s == nil ? "Using the default tracking model. " : "Using your earlier tracking model. ")
                + "Your newly trained model is \(c.summary), so it's your call: ⌃⌥B switches between the two blind (A/B), then choose below."
        }
        guard let s else {
            return sessions == 0 ? "Using the default tracking model. Record a session to train your own."
                : "Using the default tracking model. \(sessions) recorded session\(sessions == 1 ? "" : "s") ready for training."
        }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        return String(format: "Using your own tracking model (trained %@ on %.0f min): %@ than the default.",
                      df.string(from: s.trainedAt), s.minutes, s.summary)
    }
}
