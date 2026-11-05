import Foundation
import SwiftUI

/// Ein Tab: eine Verbindung (seriell, Telnet oder SSH) mit eigenen Puffern, Zählern und Skript.
@MainActor
final class Session: ObservableObject, Identifiable {
    let id: UUID
    let prefs: Prefs
    var onConfigChange: (() -> Void)?

    @Published var config: TabConfig {
        didSet { onConfigChange?() }
    }
    var kind: ConnKind { config.kind }

    // Verbindung
    @Published var ports: [String] = []
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var statusText = L("Nicht verbunden")
    @Published var modem = ModemLines()
    @Published var dtr = true {
        didSet { if isConnected, kind == .serial { serial.setLine(Ioctl.dtr, dtr) } }
    }
    @Published var rts = true {
        didSet { if isConnected, kind == .serial { serial.setLine(Ioctl.rts, rts) } }
    }
    /// Der Server fragt gerade nach einem Passwort (Telnet/SSH) → Eingabe wird maskiert.
    @Published var awaitingSecret = false

    // Ansicht dieses Tabs
    @Published var filter = ""
    @Published var showScript = false

    // Zähler
    @Published var rxCount = 0
    @Published var txCount = 0
    @Published var byteHits = 0

    // Befehls-Historie: Position beim Blättern (nil = kein Eintrag gewählt)
    @Published var historyIndex: Int?

    // Zeilen sind bewusst nicht @Published – die Views beobachten `revision`
    @Published var revision = 0
    private(set) var rxLines: [Line] = []     // empfangene Daten + Meldungen
    private(set) var txLines: [Line] = []     // gesendete Daten

    // Skript / Mitschnitt
    @Published var scriptRunning = false
    @Published var logURL: URL?

    /// Terminal-Emulation für Telnet/SSH-Tabs
    let term = TermBuffer()
    private var termCols = 80
    private var termRows = 24
    /// Telnet: eigene Eingabe lokal anzeigen (für Server ohne ECHO-Aushandlung)
    @Published var localEcho = false

    private let serial = SerialPort()
    private var transport: Transport?
    private let hub = RxHub()
    private let script = ScriptRunner()
    private var logHandle: FileHandle?
    private var wantConnected = false
    private var present: [String] = []
    private var nextId = 0
    private var lastRxTime = Date.distantPast
    private var rxViewBytes = 0

    private static let maxLines = 5_000
    private static let trimCount = 500
    private static let maxHistory = 50
    private static let hardWrapBytes = 4096
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(prefs: Prefs, config: TabConfig) {
        self.id = config.id
        self.prefs = prefs
        self.config = config
        term.onReply = { [weak self] bytes in self?.sendRaw(bytes) }
        refreshPorts()
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var title: String {
        switch config.kind {
        case .serial:
            return config.serial.path.isEmpty ? L("Seriell") : shortName(config.serial.path)
        case .telnet:
            return config.host.isEmpty ? "Telnet" : "telnet \(config.host)"
        case .ssh:
            if config.host.isEmpty { return "SSH" }
            return config.user.isEmpty ? "ssh \(config.host)" : "ssh \(config.user)@\(config.host)"
        }
    }

    /// Zeilenende beim Senden: seriell frei wählbar, Telnet CR+LF, SSH LF.
    var effectiveLineEnding: LineEnding {
        switch config.kind {
        case .serial: return prefs.data.lineEnding
        case .telnet: return .crlf
        case .ssh: return .lf
        }
    }

    // MARK: Verbindung

    func toggleConnection() {
        if isConnected || isConnecting { disconnect() } else { connect() }
    }

    func connect() {
        wantConnected = true
        switch kind {
        case .serial: openSerial(silent: false)
        case .telnet: openTelnet()
        case .ssh: openSSH()
        }
    }

    func disconnect() {
        wantConnected = false
        let was = isConnected || isConnecting
        transport?.close()
        transport = nil
        isConnected = false
        isConnecting = false
        awaitingSecret = false
        hub.connected = false
        if was {
            statusText = L("Getrennt")
            info(L("Getrennt"))
        }
    }

    private func bind(_ t: Transport) {
        let hub = self.hub
        t.onData = { bytes in hub.receive(bytes) }
        t.onClose = { [weak self] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.portLost(reason) }
            }
        }
    }

    private func markConnected(status: String, infoText: String) {
        isConnected = true
        isConnecting = false
        hub.connected = true
        statusText = status
        info(infoText)
    }

    private func fail(_ message: String, silent: Bool = false) {
        statusText = message
        if !silent { info(L("Fehler: %@", message)) }
    }

    private func openSerial(silent: Bool) {
        let cfg = config.serial
        bind(serial)
        do {
            try serial.open(cfg)
            transport = serial
            let p: String
            switch cfg.parity {
            case .none: p = "N"
            case .even: p = "E"
            case .odd: p = "O"
            }
            let desc = "\(cfg.baud) \(cfg.dataBits)\(p)\(cfg.stopBits)"
            markConnected(status: L("Verbunden mit %@ (%@)", cfg.path, desc),
                          infoText: L("Verbunden: %@ @ %@", shortName(cfg.path), desc))
            serial.setLine(Ioctl.dtr, dtr)
            serial.setLine(Ioctl.rts, rts)
        } catch {
            fail(error.localizedDescription, silent: silent)
        }
    }

    private func openTelnet() {
        let host = config.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { fail(L("Kein Host angegeben")); return }
        let t = TelnetTransport()
        bind(t)
        term.softReset()
        transport = t
        isConnecting = true
        statusText = L("Verbinde mit %@:%lld …", host, config.port)
        let port = config.port
        t.open(host: host, port: port, cols: termCols, rows: termRows) { [weak self] err in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.telnetOpened(t, host: host, port: port, error: err) }
            }
        }
    }

    private func telnetOpened(_ t: TelnetTransport, host: String, port: Int, error: String?) {
        guard transport === t, isConnecting else { return }
        if let error {
            transport = nil
            isConnecting = false
            fail(error)
        } else {
            markConnected(status: L("Verbunden mit %@:%lld (Telnet)", host, port),
                          infoText: L("Verbunden: %@:%lld (Telnet)", host, port))
        }
    }

    private func openSSH() {
        let host = config.host.trimmingCharacters(in: .whitespaces)
        let user = config.user.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { fail(L("Kein Host angegeben")); return }
        guard !host.hasPrefix("-"), !user.hasPrefix("-") else {
            fail(L("Ungültiger Host oder Benutzername"))
            return
        }
        let t = SSHTransport()
        bind(t)
        term.softReset()
        do {
            try t.open(host: host, port: config.port, user: user,
                       keyFile: config.keyFile.trimmingCharacters(in: .whitespaces),
                       extraArgs: config.extraArgs, cols: termCols, rows: termRows)
            transport = t
            let target = user.isEmpty ? host : "\(user)@\(host)"
            markConnected(status: L("SSH-Sitzung zu %@:%lld", target, config.port),
                          infoText: L("SSH gestartet: %@:%lld", target, config.port))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func portLost(_ reason: String?) {
        guard isConnected || isConnecting else { return }
        transport?.close()
        transport = nil
        isConnected = false
        isConnecting = false
        awaitingSecret = false
        hub.connected = false
        statusText = reason ?? L("Verbindung verloren")
        info(reason ?? L("Verbindung verloren"))
    }

    func sendBreak() {
        guard kind == .serial, isConnected else { return }
        serial.sendBreak()
        info(L("Break gesendet"))
    }

    func shortName(_ path: String) -> String {
        path.replacingOccurrences(of: "/dev/", with: "")
    }

    // MARK: Timer

    func refreshPorts() {
        guard kind == .serial else { return }
        present = SerialPort.availablePorts()
        var list = present
        let current = config.serial.path
        if current.isEmpty || current.hasSuffix("debug-console") {
            if let first = present.first(where: { $0.contains("usb") }) ?? present.first {
                config.serial.path = first
                list = present
            }
        } else if !list.contains(current) {
            list.append(current)
        }
        if list != ports { ports = list }
    }

    private func tick() {
        guard kind == .serial else { return }
        refreshPorts()
        if isConnected {
            let m = serial.modem()
            if m != modem { modem = m }
        } else if wantConnected, !isConnecting, prefs.data.autoReconnect,
                  present.contains(config.serial.path) {
            openSerial(silent: true)
        }
    }

    private func drain() {
        let chunks = hub.drainPending()
        guard !chunks.isEmpty else { return }
        let target = UInt8(truncatingIfNeeded: prefs.data.countByte)
        for (time, bytes) in chunks {
            if kind == .serial { ingestRx(bytes, at: time) } else { term.feed(bytes) }
            rxCount += bytes.count
            rxViewBytes += bytes.count
            for b in bytes where b == target { byteHits += 1 }
            logHandle?.write(Data(bytes))
        }
        if prefs.data.clearAtEnabled, rxViewBytes >= max(1, prefs.data.clearAtBytes) {
            rxLines.removeAll()
            rxViewBytes = 0
        }
        Self.trim(&rxLines)
        revision += 1
    }

    /// Erkennt Passwortabfragen am Ende der letzten, noch offenen Zeile (nur Telnet/SSH).
    private func updateSecretState() {
        guard kind != .serial else { return }
        var secret = false
        if let last = rxLines.last, last.dir == .rx, !last.complete {
            let t = String(decoding: last.bytes.suffix(200), as: UTF8.self)
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
            secret = t.hasSuffix(":")
                && (t.contains("password") || t.contains("passphrase") || t.contains("passwort"))
        }
        if secret != awaitingSecret { awaitingSecret = secret }
    }

    // MARK: Zeilen

    private func ingestRx(_ bytes: [UInt8], at time: Date) {
        let mode = prefs.data.rxLineMode
        let gap = Double(prefs.data.idleGapMs) / 1000
        let cap = prefs.data.wrapBytes > 0 ? prefs.data.wrapBytes : Self.hardWrapBytes
        if mode == .idle, let last = rxLines.last, last.dir == .rx, !last.complete,
           time.timeIntervalSince(lastRxTime) > gap {
            rxLines[rxLines.count - 1].complete = true
        }
        for b in bytes {
            if rxLines.last == nil || rxLines[rxLines.count - 1].dir != .rx
                || rxLines[rxLines.count - 1].complete {
                rxLines.append(Line(id: nextId, time: time, dir: .rx, bytes: [], complete: false))
                nextId += 1
            }
            let idx = rxLines.count - 1
            let prev = rxLines[idx].bytes.last
            rxLines[idx].bytes.append(b)
            switch mode {
            case .lf: if b == 10 { rxLines[idx].complete = true }
            case .cr: if b == 13 { rxLines[idx].complete = true }
            case .crlf: if b == 10 && prev == 13 { rxLines[idx].complete = true }
            case .idle: break
            }
            if rxLines[idx].bytes.count >= cap { rxLines[idx].complete = true }
        }
        lastRxTime = time
    }

    private static func trim(_ lines: inout [Line]) {
        if lines.count > maxLines { lines.removeFirst(trimCount) }
    }

    func info(_ text: String) {
        if kind != .serial {
            term.feed(Array("\r\n\u{1B}[33m[\(text)]\u{1B}[0m\r\n".utf8))
            return
        }
        rxLines.append(Line(id: nextId, time: Date(), dir: .info, bytes: Array(text.utf8), complete: true))
        nextId += 1
        Self.trim(&rxLines)
        revision += 1
    }

    func clearRx() {
        rxLines.removeAll()
        rxViewBytes = 0
        revision += 1
    }

    func clearTx() {
        txLines.removeAll()
        revision += 1
    }

    func resetRxCount() { rxCount = 0 }
    func resetTxCount() { txCount = 0 }
    func resetByteHits() { byteHits = 0 }

    func searchText(_ line: Line) -> String {
        if line.dir == .info { return String(decoding: line.bytes, as: UTF8.self) }
        return Fmt.render(line.bytes, as: .ascii)
    }

    func timeString(_ date: Date) -> String {
        Self.timeFormat.string(from: date)
    }

    func exportText(_ lines: [Line], formats: [DisplayFormat]) -> String {
        let fmts = formats.isEmpty ? [DisplayFormat.ascii] : formats
        var out: [String] = []
        for l in lines {
            let t = timeString(l.time)
            if l.dir == .info {
                out.append("\(t) # \(String(decoding: l.bytes, as: UTF8.self))")
                continue
            }
            out.append(t)
            for f in fmts {
                let tag = f.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
                out.append("  \(tag) \(Fmt.render(l.bytes, as: f))")
            }
        }
        return out.joined(separator: "\n")
    }

    func exportRx() -> String {
        kind == .serial ? exportText(rxLines, formats: prefs.data.outFormats) : term.plainText()
    }
    func exportTx() -> String { exportText(txLines, formats: prefs.data.inFormats) }

    // MARK: Senden

    /// `masked`: Passwort – wird gesendet, aber im Sendefenster nur als Sternchen gezeigt.
    func transmit(_ bytes: [UInt8], masked: Bool = false) {
        guard isConnected, !bytes.isEmpty else { return }
        transport?.write(bytes)
        txCount += bytes.count
        let shown: [UInt8] = masked ? Array("********".utf8) : bytes
        txLines.append(Line(id: nextId, time: Date(), dir: .tx, bytes: shown, complete: true))
        nextId += 1
        Self.trim(&txLines)
        revision += 1
    }

    /// Sendet ein Makro (Text mit Escapes oder Hex, optional mit Zeilenende).
    func sendMacro(_ m: Macro) {
        guard isConnected else { info(L("Nicht verbunden")); return }
        do {
            var bytes = try Fmt.parse(m.text, as: m.hex ? .hex : .ascii)
            if m.enter { bytes += kind == .serial ? prefs.data.lineEnding.bytes : [0x0D] }
            guard !bytes.isEmpty else { return }
            if kind == .serial { transmit(bytes) } else { sendRaw(bytes) }
        } catch {
            info(L("Makro „%@“: %@", m.name, error.localizedDescription))
        }
    }

    /// Tastatureingabe aus der Terminalansicht (Telnet/SSH).
    func sendRaw(_ bytes: [UInt8]) {
        guard isConnected, !bytes.isEmpty, let t = transport else { return }
        var out = bytes
        if kind == .telnet {
            // Telnet-NVT: Enter = CR LF
            out = []
            for b in bytes {
                out.append(b)
                if b == 0x0D { out.append(0x0A) }
            }
            if localEcho {
                var echo = [UInt8]()
                for b in bytes {
                    switch b {
                    case 0x0D: echo += [0x0D, 0x0A]
                    case 0x7F: echo += [0x08, 0x20, 0x08]
                    case 0x20...0x7E, 0x80...0xFF: echo.append(b)
                    default: break
                    }
                }
                term.feed(echo)
            }
        }
        t.write(out)
        txCount += bytes.count
    }

    func terminalResized(cols: Int, rows: Int) {
        termCols = cols
        termRows = rows
        transport?.resize(cols: cols, rows: rows)
    }

    @discardableResult
    func sendInput(_ text: String) -> Bool {
        guard isConnected else {
            info(L("Nicht verbunden"))
            return false
        }
        let secret = awaitingSecret && kind != .serial
        do {
            var bytes: [UInt8]
            if secret {
                bytes = Array(text.utf8)          // Passwort immer als Rohtext
            } else {
                bytes = try Fmt.parse(text, as: prefs.data.inputFormat)
            }
            bytes += effectiveLineEnding.bytes
            guard !bytes.isEmpty else { return false }
            transmit(bytes, masked: secret)
            if secret {
                awaitingSecret = false
            } else {
                addToHistory(text)
            }
            return true
        } catch {
            info(L("Eingabefehler: %@", error.localizedDescription))
            return false
        }
    }

    func sendFile(_ url: URL) {
        guard isConnected else { info(L("Nicht verbunden")); return }
        guard let data = try? Data(contentsOf: url) else {
            info(L("Datei nicht lesbar: %@", url.lastPathComponent))
            return
        }
        let bytes = [UInt8](data)
        var off = 0
        while off < bytes.count {
            let end = min(off + 1024, bytes.count)
            transport?.write(Array(bytes[off..<end]))
            off = end
        }
        txCount += bytes.count
        info(L("Datei gesendet: %@ (%lld Bytes)", url.lastPathComponent, bytes.count))
    }

    // MARK: Historie

    private func addToHistory(_ text: String) {
        historyIndex = nil
        guard !text.isEmpty else { return }
        var h = prefs.data.history
        h.removeAll { $0 == text }
        h.append(text)
        if h.count > Self.maxHistory { h.removeFirst(h.count - Self.maxHistory) }
        prefs.data.history = h
    }

    /// Blättert durch die Historie. -1 = älter, +1 = neuer.
    /// Rückgabe: neuer Eingabetext ("" nach dem neuesten Eintrag), nil wenn die Historie leer ist.
    func navigateHistory(_ delta: Int) -> String? {
        let h = prefs.data.history
        guard !h.isEmpty else { return nil }
        var i = (historyIndex ?? h.count) + delta
        if i < 0 { i = 0 }
        if i >= h.count {
            historyIndex = nil
            return ""
        }
        historyIndex = i
        return h[i]
    }

    func clearHistory() {
        prefs.data.history = []
        historyIndex = nil
    }

    // MARK: Mitschnitt

    func startLog(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            logHandle = try FileHandle(forWritingTo: url)
            logURL = url
            info(L("Mitschnitt (Rohdaten): %@", url.lastPathComponent))
        } catch {
            info(L("Mitschnitt fehlgeschlagen: %@", error.localizedDescription))
        }
    }

    func stopLog() {
        try? logHandle?.close()
        logHandle = nil
        logURL = nil
        info(L("Mitschnitt beendet"))
    }

    // MARK: Skripte

    func runScript() {
        guard !scriptRunning else { return }
        // TextEditor ersetzt je nach Systemeinstellung Anführungszeichen durch typografische
        let src = prefs.data.scriptSource
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
        hub.tapClear()
        // DispatchQueue.main garantiert die Reihenfolge von send/log aus dem Skript-Thread
        let host = ScriptHost(
            hub: hub,
            send: { [weak self] bytes in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.transmit(bytes) } }
            },
            log: { [weak self] text in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.info(text) } }
            },
            clearScreen: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.clearRx() } }
            }
        )
        scriptRunning = true
        script.run(source: src, host: host) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scriptRunning = false } }
        }
    }

    func stopScript() {
        script.stop()
    }
}
