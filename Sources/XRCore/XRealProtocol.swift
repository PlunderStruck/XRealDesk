import Foundation
import zlib

/// XREAL Air-family USB HID protocol.
///
/// Reverse-engineered by the community (TheJackiMonster/nrealAirLinuxDriver, wheaney/XRLinuxDriver)
/// and verified against an Air 2 Pro on macOS. Two HID interfaces matter:
///  - IMU: 1 kHz inertial stream plus calibration download (frame head 0xAA)
///  - MCU: firmware info, display mode, button events (frame head 0xFD)
public enum XRealProtocol {
    public static let vendorID = 0x3318

    /// EDID manufacturer code "MRG" as reported by CGDisplayVendorNumber for the glasses' display.
    public static let displayVendorNumber: UInt32 = 0x3647

    public struct Model: Sendable, Equatable {
        public let productID: Int
        public let name: String
        public let imuInterface: Int
        public let mcuInterface: Int
        public let supported: Bool
    }

    public static let models: [Model] = [
        Model(productID: 0x0424, name: "XREAL Air", imuInterface: 3, mcuInterface: 4, supported: true),
        Model(productID: 0x0428, name: "XREAL Air 2", imuInterface: 3, mcuInterface: 4, supported: true),
        Model(productID: 0x0432, name: "XREAL Air 2 Pro", imuInterface: 3, mcuInterface: 4, supported: true),
        Model(productID: 0x0426, name: "XREAL Air 2 Ultra", imuInterface: 2, mcuInterface: 0, supported: true),
    ]

    public static func model(productID: Int) -> Model? {
        models.first { $0.productID == productID }
    }

    // MARK: IMU interface

    public enum IMUMessage: UInt8 {
        case getCalibrationLength = 0x14
        case getCalibrationSegment = 0x15
        case startIMUStream = 0x19
        case getStaticID = 0x1A
    }

    /// Builds an IMU-interface command: AA | crc32 | len16 | msgid | data, zero-padded.
    public static func imuCommand(_ msg: IMUMessage, data: [UInt8] = [], reportSize: Int = 64) -> [UInt8] {
        let length = 3 + data.count
        let body = le16(length) + [msg.rawValue] + data
        return pad(frame(head: 0xAA, body: body), to: reportSize)
    }

    /// If `report` is a reply to an IMU command, returns (msgid, payload bytes after the msgid).
    public static func parseIMUReply(_ report: [UInt8]) -> (msg: UInt8, payload: ArraySlice<UInt8>)? {
        guard report.count >= 8, report[0] == 0xAA else { return nil }
        return (report[7], report[8...])
    }

    // MARK: MCU interface

    public enum MCUMessage: UInt16 {
        case readBrightness = 0x03
        case readDisplayMode = 0x07
        case writeDisplayMode = 0x08
        case readGlassesID = 0x15
        case readDPFirmware = 0x16
        case readDSPFirmware = 0x21
        case readMCUFirmware = 0x26
        case eventDisplayToggled = 0x6C04
        case eventButtonPressed = 0x6C05
    }

    /// Display modes (MCU msg 0x07/0x08). Side-by-side modes send each eye its own half of a 3840×1080 image.
    public enum DisplayMode {
        public static let mono1080p60: UInt8 = 0x01
        public static let sbs60: UInt8 = 0x03
        public static let sbs72: UInt8 = 0x04
        public static let mono1080p72: UInt8 = 0x05
        public static let sbs90: UInt8 = 0x09
        public static let mono1080p90: UInt8 = 0x0A
        public static let mono1080p120: UInt8 = 0x0B
        public static func isSideBySide(_ m: UInt8) -> Bool { m == sbs60 || m == sbs72 || m == sbs90 }
    }

    /// Builds an MCU command: FD | crc32 | len16 | timestamp64 | msgid16 | reserved[5] | data.
    public static func mcuCommand(_ msg: MCUMessage, data: [UInt8] = [], reportSize: Int = 64) -> [UInt8] {
        let length = 17 + data.count
        let body = le16(length) + [UInt8](repeating: 0, count: 8) + le16(Int(msg.rawValue)) + [0, 0, 0, 0, 0] + data
        return pad(frame(head: 0xFD, body: body), to: reportSize)
    }

    public struct MCUReply: Sendable {
        public let msg: UInt16
        public let status: UInt8
        public let payload: [UInt8]
        public var text: String { String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self) }
    }

    public static func parseMCUReply(_ report: [UInt8]) -> MCUReply? {
        guard report.count >= 23, report[0] == 0xFD else { return nil }
        let length = Int(report[5]) | Int(report[6]) << 8
        let msg = UInt16(report[15]) | UInt16(report[16]) << 8
        let dataEnd = min(report.count, 5 + max(length, 18))
        let payload = dataEnd > 23 ? Array(report[23..<dataEnd]) : []
        return MCUReply(msg: msg, status: report[22], payload: payload)
    }

    // MARK: IMU data packets

    /// One raw inertial sample in the sensor's native axes (gyro deg/s, accel g).
    public struct RawIMUSample: Sendable {
        public var timestampNs: UInt64
        public var gyro: SIMD3<Float>
        public var accel: SIMD3<Float>
        public var temperatureC: Float

        public init(timestampNs: UInt64, gyro: SIMD3<Float>, accel: SIMD3<Float>, temperatureC: Float) {
            self.timestampNs = timestampNs; self.gyro = gyro; self.accel = accel; self.temperatureC = temperatureC
        }
    }

    /// Parses a 64-byte IMU data report (signature 01 02). Returns nil for replies/other packets.
    public static func parseIMUSample(_ p: UnsafeBufferPointer<UInt8>) -> RawIMUSample? {
        guard p.count >= 64, p[0] == 0x01, p[1] == 0x02 else { return nil }
        var ts: UInt64 = 0
        for k in 0..<8 { ts |= UInt64(p[4 + k]) << (8 * k) }
        let gm = Float(i16(p, 12)), gd = Float(i32(p, 14))
        let am = Float(i16(p, 27)), ad = Float(i32(p, 29))
        guard gd != 0, ad != 0 else { return nil }
        let gyro = SIMD3<Float>(Float(i24(p, 18)), Float(i24(p, 21)), Float(i24(p, 24))) * (gm / gd)
        let accel = SIMD3<Float>(Float(i24(p, 33)), Float(i24(p, 36)), Float(i24(p, 39))) * (am / ad)
        // ICM-42688-P: 25 °C offset, 132.48 LSB/°C
        let temp = Float(i16(p, 2)) / 132.48 + 25
        return RawIMUSample(timestampNs: ts, gyro: gyro, accel: accel, temperatureC: temp)
    }

    // MARK: helpers

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { UInt32(zlib.crc32(0, $0.baseAddress, uInt($0.count))) }
    }

    static func frame(head: UInt8, body: [UInt8]) -> [UInt8] {
        let c = crc32(body)
        return [head, UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8(c >> 24)] + body
    }

    static func pad(_ bytes: [UInt8], to size: Int) -> [UInt8] {
        bytes.count >= size ? bytes : bytes + [UInt8](repeating: 0, count: size - bytes.count)
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    static func i16(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) -> Int32 {
        Int32(Int16(bitPattern: UInt16(p[o]) | UInt16(p[o + 1]) << 8))
    }

    static func i24(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) -> Int32 {
        var v = Int32(p[o]) | Int32(p[o + 1]) << 8 | Int32(p[o + 2]) << 16
        if p[o + 2] & 0x80 != 0 { v |= Int32(bitPattern: 0xFF00_0000) }
        return v
    }

    static func i32(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) -> Int32 {
        Int32(bitPattern: UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24)
    }
}
