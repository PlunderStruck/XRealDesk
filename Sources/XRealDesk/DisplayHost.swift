import CoreGraphics
import Darwin
import Foundation

/// The glasses screens live in a small helper process ("display host": this same binary run with
/// `--display-host`), not in the app. Virtual displays die with the process that made them, and
/// when they die macOS moves their windows to the Mac, often onto another Space where they can't
/// be moved back. With the host owning them, restarting or updating XRealDesk (or a crash) leaves
/// the screens, and every window on them, exactly where they were: the new XRealDesk picks them up.
///
/// The app talks to the host over a Unix socket, one JSON request/reply per line. When the app
/// disconnects without saying goodbye (quit by the system, crash, update), the host keeps the
/// screens for 20 s for the next XRealDesk to adopt, then removes them and exits.
enum DisplayHostProtocol {
    static let version = 1
    static var socketPath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/XRealDesk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("display-host.sock").path
    }

    struct Request: Codable {
        var cmd: String              // hello, sync, enforce, destroy, quit
        var count = 0, width = 0, height = 0, refreshRate = 60
        var hiDPI = false
    }
    struct ScreenInfo: Codable {
        var index: Int, id: UInt32
        var pointW: Double, pointH: Double, pixelW: Double, pixelH: Double
    }
    struct Reply: Codable {
        var version = DisplayHostProtocol.version
        var ok = true
        var result = ""              // sync: unchanged / resized / remoded / recreated
        var signature = ""
        var screens: [ScreenInfo] = []
    }
}

// MARK: - Host (runs in the helper process)

enum DisplayHost {
    private static let manager = VirtualDisplayManager()
    private static var goodbyeTimer: DispatchWorkItem?

    /// Entry point for `XRealDesk --display-host`. Never returns.
    static func run() -> Never {
        let path = DisplayHostProtocol.socketPath
        if DisplayHostClient.connect(path: path) != nil { exit(0) }   // another host is already serving
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0, bind(server, path: path), listen(server, 4) == 0 else {
            Log.error("Display host: can't listen on \(path)")
            exit(1)
        }
        Log.info("Display host started (pid \(getpid()))")
        scheduleExit(after: 20)   // nobody connects: go away
        Thread.detachNewThread {
            while true {
                let fd = accept(server, nil, nil)
                guard fd >= 0 else { continue }
                DispatchQueue.main.async { goodbyeTimer?.cancel() }
                serve(fd)
                close(fd)
                // The app went away without a goodbye: keep the screens briefly for the next one.
                DispatchQueue.main.async { scheduleExit(after: 20) }
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func scheduleExit(after seconds: Double) {
        goodbyeTimer?.cancel()
        let work = DispatchWorkItem {
            Log.info("Display host: no XRealDesk for \(Int(seconds)) s; removing the screens")
            manager.destroyAll()
            unlink(DisplayHostProtocol.socketPath)
            exit(0)
        }
        goodbyeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let req = try? JSONDecoder().decode(DisplayHostProtocol.Request.self, from: Data(line)) else { continue }
                // CGVirtualDisplay lives on the main queue.
                let reply = DispatchQueue.main.sync { handle(req) }
                guard var out = try? JSONEncoder().encode(reply) else { continue }
                out.append(0x0A)
                _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
                if req.cmd == "quit" { unlink(DisplayHostProtocol.socketPath); exit(0) }
            }
        }
    }

    private static func handle(_ req: DisplayHostProtocol.Request) -> DisplayHostProtocol.Reply {
        var reply = DisplayHostProtocol.Reply()
        switch req.cmd {
        case "sync":
            let result = manager.sync(count: req.count, resolution: ResolutionPreset(width: req.width, height: req.height),
                                      hiDPI: req.hiDPI, refreshRate: req.refreshRate)
            reply.result = "\(result)"
        case "enforce":
            reply.ok = manager.enforceModes()
        case "destroy", "quit":
            manager.destroyAll()
        default:
            break   // hello
        }
        reply.signature = manager.signature
        reply.screens = manager.screens.map {
            .init(index: $0.index, id: $0.id, pointW: $0.pointSize.width, pointH: $0.pointSize.height,
                  pixelW: $0.pixelSize.width, pixelH: $0.pixelSize.height)
        }
        return reply
    }

    private static func bind(_ fd: Int32, path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() { p[i] = b } }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
    }
}

// MARK: - Client (the app side)

/// Same interface the app used with VirtualDisplayManager, backed by the display host.
final class DisplayHostClient {
    struct Screen {
        let index: Int
        let id: CGDirectDisplayID
        var pointSize: CGSize
        var pixelSize: CGSize
    }

    private(set) var screens: [Screen] = []
    private(set) var signature = ""
    private var fd: Int32 = -1
    private var adopted = false

    /// Bring the screens in line with the settings (see VirtualDisplayManager.sync). The first sync
    /// of a session reports screens the host already had as `.recreated`, so the app starts
    /// capturing and arranging them, without them ever being removed.
    func sync(count: Int, resolution: ResolutionPreset, hiDPI: Bool, refreshRate: Int) -> VirtualDisplayManager.SyncResult {
        var req = DisplayHostProtocol.Request(cmd: "sync")
        req.count = count; req.width = resolution.width; req.height = resolution.height
        req.hiDPI = hiDPI; req.refreshRate = refreshRate
        guard let reply = send(req) else { return .unchanged }
        let firstTime = !adopted
        adopted = true
        if firstTime, !screens.isEmpty || !reply.screens.isEmpty {
            if reply.result == "unchanged" { Log.info("Adopted \(reply.screens.count) glasses screen(s) that survived the restart") }
            return .recreated
        }
        switch reply.result {
        case "resized": return .resized
        case "remoded": return .remoded
        case "recreated": return .recreated
        default: return .unchanged
        }
    }

    @discardableResult
    func enforceModes() -> Bool { send(.init(cmd: "enforce"))?.ok ?? false }

    func destroyAll() { _ = send(.init(cmd: "destroy")) }

    /// XRealDesk is really quitting: remove the screens now and stop the host.
    func quit() {
        _ = send(.init(cmd: "quit"))
        disconnect()
    }

    // MARK: Transport

    private func send(_ req: DisplayHostProtocol.Request) -> DisplayHostProtocol.Reply? {
        for attempt in 0..<2 {
            if fd < 0, !ensureHost() { return nil }
            guard var line = try? JSONEncoder().encode(req) else { return nil }
            line.append(0x0A)
            let wrote = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
            if wrote == line.count, let reply = readReply() {
                if reply.version != DisplayHostProtocol.version {
                    // A host from an older build: replace it (its screens go away once).
                    Log.info("Display host speaks version \(reply.version); restarting it")
                    _ = attempt
                    quit()
                    continue
                }
                apply(reply)
                return reply
            }
            disconnect()   // host died: start a new one and retry once
        }
        Log.error("Display host not reachable")
        return nil
    }

    private func apply(_ reply: DisplayHostProtocol.Reply) {
        signature = reply.signature
        screens = reply.screens.map {
            Screen(index: $0.index, id: $0.id, pointSize: CGSize(width: $0.pointW, height: $0.pointH),
                   pixelSize: CGSize(width: $0.pixelW, height: $0.pixelH))
        }
    }

    private func readReply() -> DisplayHostProtocol.Reply? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(chunk, count: n)
        }
        let line = buffer.prefix { $0 != 0x0A }
        return try? JSONDecoder().decode(DisplayHostProtocol.Reply.self, from: line)
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    /// Connect to the running host, or start one and connect.
    private func ensureHost() -> Bool {
        let path = DisplayHostProtocol.socketPath
        if let s = Self.connect(path: path) { fd = s; return true }
        guard let exe = Bundle.main.executablePath else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--display-host"]
        do { try p.run() } catch { Log.error("Couldn't start the display host: \(error)"); return false }
        for _ in 0..<40 {   // up to 2 s
            usleep(50_000)
            if let s = Self.connect(path: path) { fd = s; return true }
        }
        return false
    }

    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() { p[i] = b } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard ok else { close(fd); return nil }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)   // creating displays takes ~0.3 s each
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}
