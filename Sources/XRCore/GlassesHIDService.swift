import Foundation
import IOKit
import IOKit.hid
import os
import simd

/// Talks to XREAL Air-family glasses over plain IOKit HID (no driver, no XREAL SDK).
///
/// Runs on its own high-priority thread + run loop so head tracking never waits on the UI.
/// Handles hot-plug, calibration download (cached per headset), the 1 kHz IMU stream,
/// and a watchdog that restarts the stream if it stalls.
public final class GlassesHIDService: @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case searching
        case connecting(String)
        case tracking(String)
        case failed(String)
    }

    public struct Pose: Sendable {
        public var orientation: simd_quatf
        /// Angular velocity in the head frame, rad/s.
        public var angularVelocity: SIMD3<Float>
        /// `ProcessInfo.systemUptime` when the sample arrived (same clock as CACurrentMediaTime).
        public var hostTime: TimeInterval
        public var isStill: Bool
        public var warmedUp: Bool
        /// How far the head actually rotated over the last `recentWindow` seconds (radians).
        /// Caps prediction so a brief jolt can't be extrapolated into an overshoot.
        public var recentRotation: Float = .greatestFiniteMagnitude
        public static let recentWindow: Double = 0.031
        /// Never predict more than this multiple of the rotation the head just made.
        public static let predictionCap: Float = 1.5

        /// Extrapolates to `time` (same clock as hostTime) along the current rotation.
        /// Longest prediction. Must cover the whole display pipeline: ~39 ms at 120 Hz, ~68 ms at
        /// 60 Hz (side-by-side 3D), where a lower cap left the screens trailing every turn.
        public static let maxAhead = 0.08
        public func predicted(to time: TimeInterval, maxAhead: Double = Pose.maxAhead) -> simd_quatf {
            let dt = Float(min(max(time - hostTime, 0), maxAhead))
            let speed = simd_length(angularVelocity)
            // Tuned on recorded head motion (typing + turning): always predict, but never more
            // than 1.5× what the head actually did over the same span just before. Turns keep
            // their full prediction; a typing jolt that barely moved the head can't overshoot.
            var angle = speed * dt
            let cap = Pose.predictionCap * recentRotation * Float(Double(dt) / Pose.recentWindow)
            angle = min(angle, cap)
            guard angle > 1e-7, speed > 1e-6 else { return orientation }
            return (orientation * simd_quatf(angle: angle, axis: angularVelocity / speed)).normalized
        }

        public init(orientation: simd_quatf, angularVelocity: SIMD3<Float>, hostTime: TimeInterval,
                    isStill: Bool, warmedUp: Bool, recentRotation: Float = .greatestFiniteMagnitude) {
            self.recentRotation = recentRotation
            self.orientation = orientation
            self.angularVelocity = angularVelocity
            self.hostTime = hostTime
            self.isStill = isStill
            self.warmedUp = warmedUp
        }


    }

    public struct DeviceInfo: Sendable, Equatable {
        public var model: String
        public var serial: String
        public var firmware: String
        public var calibration: GlassesCalibration.Summary
        /// Display mode reported by the glasses at connect (see XRealProtocol.DisplayMode).
        public var displayMode: UInt8?
    }

    /// Current display mode as last read/written (thread-safe).
    public var displayMode: UInt8? { displayModeLock.withLock { $0 } }
    private let displayModeLock = OSAllocatedUnfairLock<UInt8?>(initialState: nil)

    // MARK: Public API (thread-safe)

    /// Called on the main queue.
    public var onStateChange: (@Sendable (State) -> Void)?
    public var onDeviceInfo: (@Sendable (DeviceInfo?) -> Void)?
    /// Physical button events (phys id, virtual id, value), main queue.
    public var onButton: (@Sendable (UInt8, UInt8, UInt8) -> Void)?
    public var logger: (@Sendable (String) -> Void)?

    public init(cacheDirectory: URL?, biasStore: GlassesBiasStore? = nil) {
        self.cacheDirectory = cacheDirectory
        self.biasStore = biasStore
    }

    public func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "XRealDesk.HID"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Drop and re-open the device (e.g. after system wake).
    /// Record raw IMU samples (device ns, gyro °/s xyz, accel g xyz; sensor axes) as CSV for
    /// `seconds`, for offline tuning with `xrcheck replay`. Head motion only, nothing else.
    public func recordIMU(to url: URL, seconds: Double) {
        perform { [weak self] in
            guard let self else { return }
            FileManager.default.createFile(atPath: url.path, contents: Data("t_ns,gx,gy,gz,ax,ay,az\n".utf8))
            self.recordHandle = try? FileHandle(forWritingTo: url)
            _ = try? self.recordHandle?.seekToEnd()
            self.recordUntil = ProcessInfo.processInfo.systemUptime + seconds
            self.recordBuffer = ""
            self.log("Recording IMU to \(url.path) for \(Int(seconds)) s")
        }
    }

    public func reconnect() {
        perform { [weak self] in
            guard let self else { return }
            self.log("Reconnect requested")
            self.teardownDevice(reason: nil)
            self.scanExistingDevices()
        }
    }

    public var pose: Pose? { poseLock.withLock { $0 } }
    public var state: State { stateLock.withLock { $0 } }
    public var calibration: GlassesCalibration { calLock.withLock { $0 } }

    /// Rough IMU packet rate over the last second.
    public var sampleRate: Double { rateLock.withLock { $0 } }

    // MARK: Internals

    private let cacheDirectory: URL?
    private weak var biasStore: GlassesBiasStore?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?

    private let poseLock = OSAllocatedUnfairLock<Pose?>(initialState: nil)
    private let stateLock = OSAllocatedUnfairLock<State>(initialState: .searching)
    private let calLock = OSAllocatedUnfairLock<GlassesCalibration>(initialState: GlassesCalibration())
    private let rateLock = OSAllocatedUnfairLock<Double>(initialState: 0)

    // HID-thread-only state
    private var imu: IOHIDDevice?
    private var mcu: IOHIDDevice?
    private var model: XRealProtocol.Model?
    private var serial = ""
    private var imuReportSize = 64
    private var mcuReportSize = 64
    private var imuBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    private var mcuBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    private var handshaking = false
    private var imuReplies: [[UInt8]] = []
    private var mcuReplies: [[UInt8]] = []
    private var filter = OrientationFilter()
    private var cal = GlassesCalibration()
    private var lastDeviceTimestamp: UInt64 = 0
    private var lastSampleHostTime: TimeInterval = 0
    private var samplesThisWindow = 0
    private var windowStart: TimeInterval = 0
    private var restartAttempts = 0
    private var streaming = false
    private var lastBiasSave: TimeInterval = 0
    private var predictionOmega = SIMD3<Float>(repeating: 0)
    /// Recent orientations (1 per sample, ~64 ms) for the prediction cap.
    private var history = [(t: TimeInterval, q: simd_quatf)](repeating: (0, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)), count: 64)
    private var historyIndex = 0
    private var healthWindowStart: TimeInterval = 0
    private var healthSamples = 0
    private var healthSteadySamples = 0
    private var lastTemperature: Float = 0
    private var pendingConnect = false
    private var lastRescan: TimeInterval = 0

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: XRealProtocol.vendorID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<GlassesHIDService>.fromOpaque(ctx).takeUnretainedValue()
            me.scheduleConnect()
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<GlassesHIDService>.fromOpaque(ctx).takeUnretainedValue()
            if device == me.imu || device == me.mcu { me.teardownDevice(reason: nil) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m

        // Watchdog: restart a stalled stream, surface failures.
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1, 0.5, 0, 0) { [weak self] _ in
            self?.watchdog()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)

        setState(.searching)
        scanExistingDevices()
        CFRunLoopRun()
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    /// Matching callbacks fire once per HID interface; coalesce them into one connect attempt.
    private func scheduleConnect() {
        guard !pendingConnect else { return }
        pendingConnect = true
        let t = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.3, 0, 0, 0) { [weak self] _ in
            self?.pendingConnect = false
            self?.scanExistingDevices()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .defaultMode)
    }

    private func scanExistingDevices() {
        guard imu == nil, !handshaking, let manager else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        for d in devices {
            let pid = intProp(d, kIOHIDProductIDKey) ?? -1
            guard let model = XRealProtocol.model(productID: pid) else { continue }
            guard interfaceNumber(d) == model.imuInterface else { continue }
            let location = intProp(d, kIOHIDLocationIDKey)
            let mcu = devices.first {
                intProp($0, kIOHIDLocationIDKey) == location && interfaceNumber($0) == model.mcuInterface
            }
            connect(imu: d, mcu: mcu, model: model)
            return
        }
        if !devices.isEmpty {
            let pids = Set(devices.compactMap { intProp($0, kIOHIDProductIDKey) }).map { String(format: "0x%04x", $0) }
            log("XREAL device(s) present but not a supported Air model: \(pids)")
            setState(.failed("Unsupported XREAL model (\(pids.joined(separator: ", "))). Air, Air 2, Air 2 Pro and Air 2 Ultra are supported."))
        }
    }

    private func connect(imu dev: IOHIDDevice, mcu mcuDev: IOHIDDevice?, model: XRealProtocol.Model) {
        handshaking = true
        defer { handshaking = false }
        setState(.connecting(model.name))
        serial = (IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String) ?? "unknown"
        log("Found \(model.name) serial \(serial)")

        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            log(String(format: "IOHIDDeviceOpen(IMU) failed 0x%08x", r))
            setState(.failed("Couldn't open the glasses' motion sensor. Quit other XREAL apps (Nebula, XREAL for Mac) and replug."))
            return
        }
        imu = dev
        self.model = model
        imuReportSize = max(64, intProp(dev, kIOHIDMaxOutputReportSizeKey) ?? 64)
        let inSize = max(64, intProp(dev, kIOHIDMaxInputReportSizeKey) ?? 64)
        imuBuffer.deallocate(); imuBuffer = .allocate(capacity: inSize)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, imuBuffer, inSize, { ctx, result, _, _, _, report, length in
            guard let ctx, result == kIOReturnSuccess else { return }
            Unmanaged<GlassesHIDService>.fromOpaque(ctx).takeUnretainedValue()
                .handleIMUReport(UnsafeBufferPointer(start: report, count: length))
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        var firmware = ""
        if let mcuDev, IOHIDDeviceOpen(mcuDev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            mcu = mcuDev
            mcuReportSize = max(64, intProp(mcuDev, kIOHIDMaxOutputReportSizeKey) ?? 64)
            let mIn = max(64, intProp(mcuDev, kIOHIDMaxInputReportSizeKey) ?? 64)
            mcuBuffer.deallocate(); mcuBuffer = .allocate(capacity: mIn)
            IOHIDDeviceRegisterInputReportCallback(mcuDev, mcuBuffer, mIn, { ctx, result, _, _, _, report, length in
                guard let ctx, result == kIOReturnSuccess else { return }
                Unmanaged<GlassesHIDService>.fromOpaque(ctx).takeUnretainedValue()
                    .handleMCUReport(Array(UnsafeBufferPointer(start: report, count: length)))
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(mcuDev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            if let reply = mcuRequest(.readMCUFirmware) { firmware = reply.text }
            if let mode = mcuRequest(.readDisplayMode)?.payload.first {
                displayModeLock.withLock { $0 = mode }
                log(String(format: "Glasses display mode 0x%02x", mode))
            }
        }

        // Pause the stream while we talk to the IMU interface.
        _ = imuRequest(.startIMUStream, data: [0], timeout: 0.5)
        pump(0.05)
        imuReplies.removeAll()

        cal = loadCalibration() ?? GlassesCalibration()
        calLock.withLock { $0 = cal }
        log(String(format: "Calibration: %@ fov %.1f°×%.1f°", cal.isFactory ? "factory" : "defaults", cal.fovDegrees.x, cal.fovDegrees.y))

        filter.reset()
        if let b = biasStore?.loadBias(serial: serial) { filter.seedBias(b) }
        lastDeviceTimestamp = 0
        streaming = false
        restartAttempts = 0

        // Unplugged mid-handshake? The removal callback already tore down; don't report stale state.
        guard imu == dev else { return }
        guard imuRequest(.startIMUStream, data: [1], timeout: 1.0) != nil || sawSampleRecently() else {
            guard imu == dev else { return }
            log("IMU did not acknowledge stream start")
            setState(.failed("The glasses didn't start their motion stream. Unplug and replug them."))
            return
        }
        guard imu == dev else { return }
        lastSampleHostTime = ProcessInfo.processInfo.systemUptime
        let info = DeviceInfo(model: model.name, serial: serial, firmware: firmware, calibration: cal.summary,
                              displayMode: displayMode)
        DispatchQueue.main.async { [onDeviceInfo] in onDeviceInfo?(info) }
        setState(.tracking(model.name))
    }

    private func teardownDevice(reason: String?) {
        if let imu {
            IOHIDDeviceRegisterInputReportCallback(imu, imuBuffer, 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(imu, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(imu, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let mcu {
            IOHIDDeviceRegisterInputReportCallback(mcu, mcuBuffer, 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(mcu, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(mcu, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        let hadDevice = imu != nil
        imu = nil; mcu = nil; model = nil; streaming = false
        poseLock.withLock { $0 = nil }
        rateLock.withLock { $0 = 0 }
        if hadDevice {
            log("Glasses disconnected")
            DispatchQueue.main.async { [onDeviceInfo] in onDeviceInfo?(nil) }
        }
        setState(reason.map { .failed($0) } ?? .searching)
    }

    // MARK: Report handling

    private func handleIMUReport(_ p: UnsafeBufferPointer<UInt8>) {
        if let s = XRealProtocol.parseIMUSample(p) {
            ingest(s)
        } else if handshaking, p.count > 0, p[0] == 0xAA {
            imuReplies.append(Array(p))
        }
    }

    private func handleMCUReport(_ bytes: [UInt8]) {
        guard let reply = XRealProtocol.parseMCUReply(bytes) else { return }
        if reply.msg == XRealProtocol.MCUMessage.eventButtonPressed.rawValue, bytes.count > 30 {
            let phys = bytes[22], virt = bytes[26], value = bytes[30]
            DispatchQueue.main.async { [onButton] in onButton?(phys, virt, value) }
        } else if handshaking {
            mcuReplies.append(bytes)
        }
    }

    private var recordHandle: FileHandle?
    private var recordUntil: TimeInterval = 0
    private var recordBuffer = ""

    private func ingest(_ s: XRealProtocol.RawIMUSample) {
        let now = ProcessInfo.processInfo.systemUptime
        if let h = recordHandle {
            recordBuffer += "\(s.timestampNs),\(s.gyro.x),\(s.gyro.y),\(s.gyro.z),\(s.accel.x),\(s.accel.y),\(s.accel.z)\n"
            if recordBuffer.utf8.count > 64_000 || now > recordUntil {
                h.write(Data(recordBuffer.utf8)); recordBuffer = ""
            }
            if now > recordUntil {
                try? h.close(); recordHandle = nil
                log("IMU recording finished")
            }
        }
        var dt: Float = 0.001
        if lastDeviceTimestamp != 0, s.timestampNs > lastDeviceTimestamp {
            dt = Float(Double(s.timestampNs - lastDeviceTimestamp) / 1e9)
        }
        lastDeviceTimestamp = s.timestampNs
        lastSampleHostTime = now
        streaming = true

        let (g, a) = cal.correct(s)
        filter.update(gyro: g, accel: a, dt: dt)
        guard filter.initialized else { return }

        // Smoothed rate for prediction (~8 ms): removes per-sample gyro noise and single-jolt
        // spikes; tuned on recorded head motion.
        let predAlpha = min(1, dt / 0.008)
        predictionOmega += (filter.angularVelocity - predictionOmega) * predAlpha
        history[historyIndex] = (now, filter.orientation)
        historyIndex = (historyIndex + 1) % history.count
        var recent: Float = .greatestFiniteMagnitude
        for k in 1..<history.count {   // newest sample at least `recentWindow` old
            let h = history[(historyIndex - 1 - k + history.count * 2) % history.count]
            if h.t > 0 && now - h.t >= Pose.recentWindow {
                let d = h.q.inverse * filter.orientation
                recent = 2 * acos(min(1, abs(d.real)))   // shortest rotation angle
                break
            }
        }
        let pose = Pose(orientation: filter.orientation, angularVelocity: predictionOmega,
                        hostTime: now, isStill: filter.isStill, warmedUp: filter.elapsed > 1.2, recentRotation: recent)
        poseLock.withLock { $0 = pose }

        // Tracking health, logged every 30 s: drift correction, steadiness, temperature.
        lastTemperature = s.temperatureC
        healthSamples += 1
        if filter.isStill { healthSteadySamples += 1 }
        if healthWindowStart == 0 { healthWindowStart = now }
        if now - healthWindowStart >= 30 {
            let b = filter.learnedBias * (180 / .pi)
            let tb = filter.tiltBias * (180 / .pi)
            log(String(format: "Tracking health: drift correction (%.3f, %.3f, %.3f) °/s, tilt correction (%.3f, %.3f, %.3f) °/s, level within %.2f°, steady %.0f%% of last 30 s, IMU %.1f °C",
                       b.x, b.y, b.z, tb.x, tb.y, tb.z, filter.tiltError * 180 / .pi,
                       100 * Double(healthSteadySamples) / Double(max(healthSamples, 1)), lastTemperature))
            healthWindowStart = now; healthSamples = 0; healthSteadySamples = 0
        }

        samplesThisWindow += 1
        if now - windowStart >= 1 {
            let rate = Double(samplesThisWindow) / (now - windowStart)
            rateLock.withLock { $0 = rate }
            samplesThisWindow = 0
            windowStart = now
        }
        if filter.isStill, now - lastBiasSave > 30 {
            lastBiasSave = now
            biasStore?.saveBias(filter.learnedBias, serial: serial)
        }
    }

    private func watchdog() {
        guard !handshaking else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if imu == nil {
            // Nothing open (never found, or open failed): rescan every few seconds.
            if now - lastRescan > 3 { lastRescan = now; scanExistingDevices() }
            return
        }
        let silence = now - lastSampleHostTime
        if silence > 1.0 {
            restartAttempts += 1
            log(String(format: "IMU stream stalled for %.1fs, restart attempt %d", silence, restartAttempts))
            rateLock.withLock { $0 = 0 }
            if restartAttempts > 4 {
                teardownDevice(reason: nil)
                scanExistingDevices()
                return
            }
            if let imu {
                IOHIDDeviceSetReport(imu, kIOHIDReportTypeOutput, 0,
                                     XRealProtocol.imuCommand(.startIMUStream, data: [1], reportSize: imuReportSize), imuReportSize)
            }
            if case .tracking(let n) = state { setState(.connecting(n)) }
        } else if streaming {
            if restartAttempts > 0, let model { setState(.tracking(model.name)) }
            restartAttempts = 0
        }
    }

    private func sawSampleRecently() -> Bool {
        ProcessInfo.processInfo.systemUptime - lastSampleHostTime < 0.3 && streaming
    }

    // MARK: Request / reply (HID thread; pumps the run loop while waiting)

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.002, true) }
    }

    private func imuRequest(_ msg: XRealProtocol.IMUMessage, data: [UInt8] = [], timeout: TimeInterval = 0.5) -> [UInt8]? {
        guard let imu else { return nil }
        imuReplies.removeAll()
        let packet = XRealProtocol.imuCommand(msg, data: data, reportSize: imuReportSize)
        guard IOHIDDeviceSetReport(imu, kIOHIDReportTypeOutput, 0, packet, packet.count) == kIOReturnSuccess else { return nil }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let i = imuReplies.firstIndex(where: { XRealProtocol.parseIMUReply($0)?.msg == msg.rawValue }) {
                return imuReplies.remove(at: i)
            }
            CFRunLoopRunInMode(.defaultMode, 0.002, true)
        }
        return nil
    }

    private func mcuRequest(_ msg: XRealProtocol.MCUMessage, data: [UInt8] = [], timeout: TimeInterval = 0.5) -> XRealProtocol.MCUReply? {
        guard let mcu else { return nil }
        mcuReplies.removeAll()
        let packet = XRealProtocol.mcuCommand(msg, data: data, reportSize: mcuReportSize)
        guard IOHIDDeviceSetReport(mcu, kIOHIDReportTypeOutput, 0, packet, packet.count) == kIOReturnSuccess else { return nil }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let i = mcuReplies.firstIndex(where: { XRealProtocol.parseMCUReply($0)?.msg == msg.rawValue }) {
                return XRealProtocol.parseMCUReply(mcuReplies.remove(at: i))
            }
            CFRunLoopRunInMode(.defaultMode, 0.002, true)
        }
        return nil
    }

    // MARK: Calibration

    private var cacheURL: URL? {
        let safe = serial.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return cacheDirectory?.appendingPathComponent("calibration-\(safe).json")
    }

    private func loadCalibration() -> GlassesCalibration? {
        if let url = cacheURL, let data = try? Data(contentsOf: url), let c = GlassesCalibration.parse(json: data) {
            return c
        }
        guard let data = downloadCalibration() else { return nil }
        guard let c = GlassesCalibration.parse(json: data) else {
            log("Calibration blob did not parse (\(data.count) bytes)")
            return nil
        }
        if let url = cacheURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        return c
    }

    private func downloadCalibration() -> Data? {
        guard let reply = imuRequest(.getCalibrationLength), reply.count >= 12 else {
            log("No calibration length reply")
            return nil
        }
        let length = Int(reply[8]) | Int(reply[9]) << 8 | Int(reply[10]) << 16 | Int(reply[11]) << 24
        guard length > 0, length < 1_000_000 else { return nil }
        let chunk = imuReportSize - 8
        var out = Data(capacity: length)
        while out.count < length {
            guard let seg = imuRequest(.getCalibrationSegment), seg.count >= 8 else {
                log("Calibration download stalled at \(out.count)/\(length)")
                return nil
            }
            let n = min(chunk, length - out.count, seg.count - 8)
            out.append(contentsOf: seg[8..<(8 + n)])
        }
        log("Downloaded factory calibration (\(length) bytes)")
        return out
    }

    // MARK: Helpers

    private func setState(_ s: State) {
        let changed = stateLock.withLock { old -> Bool in
            defer { old = s }
            return old != s
        }
        guard changed else { return }
        DispatchQueue.main.async { [onStateChange] in onStateChange?(s) }
    }

    private func log(_ s: String) { logger?(s) }

    private func intProp(_ d: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(d, key as CFString) as? Int
    }

    private func interfaceNumber(_ d: IOHIDDevice) -> Int {
        IORegistryEntrySearchCFProperty(IOHIDDeviceGetService(d), kIOServicePlane, "bInterfaceNumber" as CFString,
                                        kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? Int ?? -1
    }
}

/// Persists the learned gyro bias per headset so yaw is stable from the first second.
public protocol GlassesBiasStore: AnyObject, Sendable {
    func loadBias(serial: String) -> SIMD3<Float>?
    func saveBias(_ bias: SIMD3<Float>, serial: String)
}

extension GlassesCalibration {
    public struct Summary: Sendable, Equatable {
        public var factory: Bool
        public var fov: SIMD2<Float>
    }
    public var summary: Summary { Summary(factory: isFactory, fov: fovDegrees) }
}
