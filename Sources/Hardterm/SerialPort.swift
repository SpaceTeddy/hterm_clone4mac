import Foundation
import Darwin

// MARK: - Konfiguration

enum Parity: String, CaseIterable, Codable, Identifiable {
    case none = "Keine", even = "Gerade", odd = "Ungerade"
    var id: String { rawValue }
}

enum FlowControl: String, CaseIterable, Codable, Identifiable {
    case none = "Keine", rtsCts = "RTS/CTS", xonXoff = "XON/XOFF"
    var id: String { rawValue }
}

struct PortConfig: Codable, Equatable {
    var path = ""
    var baud = 115200
    var dataBits = 8
    var stopBits = 1
    var parity: Parity = .none
    var flow: FlowControl = .none
}

struct ModemLines: Equatable {
    var cts = false
    var dsr = false
    var dcd = false
    var ri = false
}

enum SerialError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}

/// macOS-ioctl-Konstanten (die C-Makros werden von Swift nicht importiert).
enum Ioctl {
    static let iossiospeed: UInt = 0x8008_5402   // _IOW('T', 2, speed_t)
    static let tiocmget: UInt = 0x4004_746A
    static let tiocmbis: UInt = 0x8004_746C
    static let tiocmbic: UInt = 0x8004_746B
    static let tiocexcl: UInt = 0x2000_740D
    static let dtr: Int32 = 0x002
    static let rts: Int32 = 0x004
    static let cts: Int32 = 0x020
    static let dcd: Int32 = 0x040
    static let ri: Int32 = 0x080
    static let dsr: Int32 = 0x100
}

// MARK: - Port

final class SerialPort: @unchecked Sendable {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let stateLock = NSLock()
    private let readQueue = DispatchQueue(label: "hardterm.serial.read")
    private let writeQueue = DispatchQueue(label: "hardterm.serial.write")

    /// Wird auf einer Hintergrund-Queue aufgerufen.
    var onData: (@Sendable ([UInt8]) -> Void)?
    /// Wird aufgerufen, wenn das Gerät verschwindet (z. B. USB abgezogen).
    var onClose: (@Sendable (String?) -> Void)?

    var isOpen: Bool { fd >= 0 }

    static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") && $0 != "cu.Bluetooth-Incoming-Port" && $0 != "cu.debug-console" }
            .sorted()
            .map { "/dev/" + $0 }
    }

    func open(_ cfg: PortConfig) throws {
        close()
        guard !cfg.path.isEmpty else { throw SerialError.failed(L("Kein Port ausgewählt")) }

        let f = Darwin.open(cfg.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else {
            throw SerialError.failed("\(cfg.path): \(String(cString: strerror(errno)))")
        }
        _ = ioctl(f, Ioctl.tiocexcl)   // exklusiver Zugriff

        var t = termios()
        guard tcgetattr(f, &t) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(f)
            throw SerialError.failed("tcgetattr: \(msg)")
        }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | 0x0003_0000)

        switch cfg.dataBits {
        case 5: t.c_cflag |= tcflag_t(CS5)
        case 6: t.c_cflag |= tcflag_t(CS6)
        case 7: t.c_cflag |= tcflag_t(CS7)
        default: t.c_cflag |= tcflag_t(CS8)
        }
        if cfg.stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) }
        switch cfg.parity {
        case .none: break
        case .even: t.c_cflag |= tcflag_t(PARENB)
        case .odd: t.c_cflag |= tcflag_t(PARENB | PARODD)
        }
        switch cfg.flow {
        case .none: break
        case .rtsCts: t.c_cflag |= 0x0003_0000          // CCTS_OFLOW | CRTS_IFLOW
        case .xonXoff: t.c_iflag |= tcflag_t(IXON | IXOFF)
        }

        cfsetspeed(&t, speed_t(cfg.baud))
        var ok = tcsetattr(f, TCSANOW, &t) == 0
        if !ok {
            // Fallback für exotische Baudraten: erst Standardrate, dann IOSSIOSPEED
            cfsetspeed(&t, 38400)
            ok = tcsetattr(f, TCSANOW, &t) == 0
            if ok {
                var s = speed_t(cfg.baud)
                ok = ioctl(f, Ioctl.iossiospeed, &s) == 0
            }
        }
        guard ok else {
            Darwin.close(f)
            throw SerialError.failed(L("Konfiguration (%lld Baud) wurde vom Treiber abgelehnt", cfg.baud))
        }
        tcflush(f, TCIOFLUSH)

        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: readQueue)
        src.setEventHandler { [weak self] in self?.readAvailable(f) }
        src.setCancelHandler { Darwin.close(f) }

        stateLock.lock()
        fd = f
        source = src
        stateLock.unlock()
        src.resume()
    }

    func close() {
        teardown()
    }

    private func teardown() {
        stateLock.lock()
        let s = source
        source = nil
        fd = -1
        stateLock.unlock()
        s?.cancel()
    }

    private func readAvailable(_ f: Int32) {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(f, &buf, buf.count)
        if n > 0 {
            onData?(Array(buf[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            guard fd == f else { return }
            teardown()
            onClose?(L("Verbindung getrennt"))
        }
    }

    func write(_ bytes: [UInt8]) {
        let f = fd
        guard f >= 0, !bytes.isEmpty else { return }
        writeQueue.async { [weak self] in
            var off = 0
            while off < bytes.count {
                guard let self, self.fd == f else { return }
                let n = bytes.withUnsafeBytes { raw in
                    Darwin.write(f, raw.baseAddress! + off, bytes.count - off)
                }
                if n > 0 {
                    off += n
                } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    usleep(1000)
                } else {
                    return
                }
            }
        }
    }

    // MARK: Steuerleitungen

    func setLine(_ bit: Int32, _ on: Bool) {
        let f = fd
        guard f >= 0 else { return }
        var b = bit
        _ = ioctl(f, on ? Ioctl.tiocmbis : Ioctl.tiocmbic, &b)
    }

    func modem() -> ModemLines {
        let f = fd
        guard f >= 0 else { return ModemLines() }
        var s: Int32 = 0
        _ = ioctl(f, Ioctl.tiocmget, &s)
        return ModemLines(cts: s & Ioctl.cts != 0,
                          dsr: s & Ioctl.dsr != 0,
                          dcd: s & Ioctl.dcd != 0,
                          ri: s & Ioctl.ri != 0)
    }

    func sendBreak() {
        let f = fd
        if f >= 0 { tcsendbreak(f, 0) }
    }
}
