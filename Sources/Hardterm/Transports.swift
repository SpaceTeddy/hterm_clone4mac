import Foundation
import Network

/// Gemeinsame Schnittstelle für serielle Ports, Telnet und SSH.
protocol Transport: AnyObject {
    var onData: (@Sendable ([UInt8]) -> Void)? { get set }
    var onClose: (@Sendable (String?) -> Void)? { get set }
    func write(_ bytes: [UInt8])
    func close()
    /// Terminalgröße hat sich geändert (nur Telnet/SSH relevant).
    func resize(cols: Int, rows: Int)
}

extension Transport {
    func resize(cols: Int, rows: Int) {}
}

extension SerialPort: Transport {}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// true nur beim ersten Aufruf
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Telnet

/// Telnet über TCP (Network.framework) mit minimaler Aushandlung:
/// ECHO und SGA werden akzeptiert, alle anderen Optionen abgelehnt. 0xFF wird beim Senden verdoppelt.
final class TelnetTransport: Transport, @unchecked Sendable {
    var onData: (@Sendable ([UInt8]) -> Void)?
    var onClose: (@Sendable (String?) -> Void)?

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "hardterm.telnet")
    private let lock = NSLock()
    private var closedByUs = false

    // Parser-Zustand: 0 Daten, 1 nach IAC, 2 nach WILL/WONT/DO/DONT, 3 in Subnegotiation, 4 SB + IAC
    private var state = 0
    private var cmd: UInt8 = 0
    private var sb = [UInt8]()
    private var answeredDo = Set<UInt8>()
    private var answeredWill = Set<UInt8>()
    private var nawsOn = false
    private var cols = 80
    private var rows = 24

    private static let IAC: UInt8 = 255
    private static let DONT: UInt8 = 254
    private static let DO: UInt8 = 253
    private static let WONT: UInt8 = 252
    private static let WILL: UInt8 = 251
    private static let SB: UInt8 = 250
    private static let SE: UInt8 = 240

    /// `completion` wird genau einmal aufgerufen: nil = verbunden, sonst Fehlertext.
    func open(host: String, port: Int, cols: Int, rows: Int, completion: @escaping @Sendable (String?) -> Void) {
        self.cols = cols
        self.rows = rows
        guard port > 0, port < 65536, let p = NWEndpoint.Port(rawValue: UInt16(port)) else {
            completion(L("Ungültiger Port"))
            return
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        conn = c
        let once = Once()
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                if once.fire() { completion(nil) }
                self?.receiveLoop()
            case .failed(let e):
                if once.fire() {
                    completion(e.localizedDescription)
                } else {
                    self?.finish(L("Verbindung getrennt: %@", e.localizedDescription))
                }
            case .waiting(let e):
                if once.fire() {
                    completion(L("Nicht erreichbar: %@", e.localizedDescription))
                    c.cancel()
                }
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let out = self.process([UInt8](data))
                if !out.isEmpty { self.onData?(out) }
            }
            if let error {
                self.finish(L("Verbindung getrennt: %@", error.localizedDescription))
                return
            }
            if isComplete {
                self.finish(L("Verbindung vom Server beendet"))
                return
            }
            self.receiveLoop()
        }
    }

    private func finish(_ reason: String) {
        lock.lock()
        let already = closedByUs
        closedByUs = true
        lock.unlock()
        guard !already else { return }
        conn?.cancel()
        onClose?(reason)
    }

    func close() {
        lock.lock()
        closedByUs = true
        lock.unlock()
        conn?.cancel()
        conn = nil
    }

    func write(_ bytes: [UInt8]) {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        for b in bytes {
            out.append(b)
            if b == Self.IAC { out.append(Self.IAC) }
        }
        send(out)
    }

    private func send(_ bytes: [UInt8]) {
        conn?.send(content: Data(bytes), completion: .contentProcessed({ _ in }))
    }

    /// Filtert Telnet-Steuerfolgen heraus und beantwortet Optionsverhandlungen.
    private func process(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        for b in bytes {
            switch state {
            case 0:
                if b == Self.IAC { state = 1 } else { out.append(b) }
            case 1:
                if b == Self.IAC {
                    out.append(Self.IAC)
                    state = 0
                } else if b >= Self.WILL && b <= Self.DONT {
                    cmd = b
                    state = 2
                } else if b == Self.SB {
                    sb.removeAll()
                    state = 3
                } else {
                    state = 0
                }
            case 2:
                respond(cmd: cmd, option: b)
                state = 0
            case 3:
                if b == Self.IAC { state = 4 } else if sb.count < 256 { sb.append(b) }
            default:
                if b == Self.SE {
                    handleSubnegotiation()
                    state = 0
                } else {
                    if b == Self.IAC { sb.append(b) }
                    state = 3
                }
            }
        }
        return out
    }

    private func handleSubnegotiation() {
        // TERMINAL-TYPE SEND → IS xterm-256color
        if sb.count >= 2, sb[0] == 24, sb[1] == 1 {
            send([Self.IAC, Self.SB, 24, 0] + Array("xterm-256color".utf8) + [Self.IAC, Self.SE])
        }
        sb.removeAll()
    }

    private func sendWindowSize() {
        func be(_ v: Int) -> [UInt8] {
            let hi = UInt8((v >> 8) & 0xFF), lo = UInt8(v & 0xFF)
            var r = [UInt8]()
            for x in [hi, lo] {
                r.append(x)
                if x == Self.IAC { r.append(x) }
            }
            return r
        }
        send([Self.IAC, Self.SB, 31] + be(cols) + be(rows) + [Self.IAC, Self.SE])
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        if nawsOn { sendWindowSize() }
    }

    private func respond(cmd: UInt8, option: UInt8) {
        switch cmd {
        case Self.WILL:
            guard answeredWill.insert(option).inserted else { return }
            let accept = option == 1 || option == 3          // ECHO, SUPPRESS-GO-AHEAD
            send([Self.IAC, accept ? Self.DO : Self.DONT, option])
        case Self.DO:
            guard answeredDo.insert(option).inserted else { return }
            switch option {
            case 24, 3:                                      // TERMINAL-TYPE, SUPPRESS-GO-AHEAD
                send([Self.IAC, Self.WILL, option])
            case 31:                                         // NAWS (Fenstergröße)
                send([Self.IAC, Self.WILL, option])
                nawsOn = true
                sendWindowSize()
            default:
                send([Self.IAC, Self.WONT, option])
            }
        default:
            break                                            // WONT/DONT brauchen keine Antwort
        }
    }
}

// MARK: - SSH

/// SSH über das System-ssh in einem echten Pseudo-Terminal (Größe änderbar, Passwortabfragen,
/// vim/top funktionieren). Ohne Perl wird ersatzweise /usr/bin/script verwendet (feste Größe).
final class SSHTransport: Transport, @unchecked Sendable {
    var onData: (@Sendable ([UInt8]) -> Void)?
    var onClose: (@Sendable (String?) -> Void)?

    private var process: Process?
    private var readFD: Int32 = -1
    private var writeFD: Int32 = -1
    private var isPty = false
    private let lock = NSLock()
    private var closedByUs = false

    private static let tiocswinsz = 0x8008_7467 as UInt  // TIOCSWINSZ

    struct SSHError: LocalizedError {
        let errorDescription: String?
    }

    func open(host: String, port: Int, user: String, keyFile: String, extraArgs: String,
              cols: Int, rows: Int) throws {
        var ssh = ["/usr/bin/ssh", "-p", String(port)]
        if !keyFile.isEmpty { ssh += ["-i", keyFile] }
        ssh += extraArgs.split(whereSeparator: { $0 == " " }).map(String.init)
        ssh.append(user.isEmpty ? host : "\(user)@\(host)")

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = String(cols)
        env["LINES"] = String(rows)

        let p = Process()
        p.environment = env
        let perl = "/usr/bin/perl"

        if FileManager.default.isExecutableFile(atPath: perl) {
            // Eigenes PTY, ssh bekommt es als steuerndes Terminal (setsid + TIOCSCTTY).
            let m = posix_openpt(O_RDWR | O_NOCTTY)
            guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let namePtr = ptsname(m) else {
                if m >= 0 { Darwin.close(m) }
                throw SSHError(errorDescription: L("Pseudo-Terminal konnte nicht angelegt werden"))
            }
            let slaveName = String(cString: namePtr)
            let s = Darwin.open(slaveName, O_RDWR | O_NOCTTY)
            guard s >= 0 else {
                Darwin.close(m)
                throw SSHError(errorDescription: L("Pseudo-Terminal konnte nicht geöffnet werden"))
            }
            var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(m, Self.tiocswinsz, &ws)

            let script = "require POSIX; if (my $pid = fork) { $SIG{TERM} = sub { kill 15, $pid }; waitpid($pid, 0); exit($? >> 8) } "
                + "POSIX::setsid(); ioctl(STDIN, 0x20007461, 0); exec @ARGV or die \"exec: $!\";"
            p.executableURL = URL(fileURLWithPath: perl)
            p.arguments = ["-e", script] + ssh
            let h = FileHandle(fileDescriptor: s, closeOnDealloc: false)
            p.standardInput = h
            p.standardOutput = h
            p.standardError = h
            p.terminationHandler = { [weak self] proc in
                self?.finish(L("SSH beendet (Exit-Code %lld)", Int(proc.terminationStatus)))
            }
            do {
                try p.run()
            } catch {
                Darwin.close(s)
                Darwin.close(m)
                throw error
            }
            Darwin.close(s)
            readFD = m
            writeFD = m
            isPty = true
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            p.arguments = ["-q", "/dev/null", "/bin/sh", "-c",
                           "stty cols \(cols) rows \(rows) 2>/dev/null; exec \"$@\"", "sh"] + ssh
            let inPipe = Pipe()
            let outPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = outPipe
            p.terminationHandler = { [weak self] proc in
                self?.finish(L("SSH beendet (Exit-Code %lld)", Int(proc.terminationStatus)))
            }
            try p.run()
            readFD = dup(outPipe.fileHandleForReading.fileDescriptor)
            writeFD = dup(inPipe.fileHandleForWriting.fileDescriptor)
            isPty = false
        }
        process = p

        let fd = readFD
        let wfd = writeFD
        let t = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    self?.onData?(Array(buf[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            Darwin.close(fd)
            if wfd != fd { Darwin.close(wfd) }
            self?.finish(L("SSH-Sitzung beendet"))
        }
        t.name = "hardterm.ssh.read"
        t.start()
    }

    func write(_ bytes: [UInt8]) {
        let fd = writeFD
        guard fd >= 0 else { return }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                off += n
            } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                continue
            } else {
                break
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard isPty, writeFD >= 0 else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(writeFD, Self.tiocswinsz, &ws)
    }

    private func finish(_ reason: String) {
        lock.lock()
        let already = closedByUs
        closedByUs = true
        lock.unlock()
        guard !already else { return }
        onClose?(reason)
    }

    func close() {
        lock.lock()
        closedByUs = true
        let w = writeFD
        writeFD = -1
        lock.unlock()
        _ = w
        // ssh wird beendet; dadurch endet der Lesethread und schließt die Dateideskriptoren
        process?.terminate()
        process = nil
    }
}
