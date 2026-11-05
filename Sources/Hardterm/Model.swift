import Foundation
import AppKit

// MARK: - Zeilenmodell

enum Direction { case rx, tx, info }

struct Line: Identifiable {
    let id: Int
    let time: Date
    let dir: Direction
    var bytes: [UInt8]
    var complete: Bool
}

// MARK: - Thread-sicherer Puffer zwischen Lese-Queue, UI und Skript-Thread

final class RxHub: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(Date, [UInt8])] = []
    private var tapBuffer = Data()
    private var isConnected = false

    var connected: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isConnected }
        set { lock.lock(); isConnected = newValue; lock.unlock() }
    }

    /// Von der Lese-Queue aufgerufen.
    func receive(_ bytes: [UInt8]) {
        let now = Date()
        lock.lock()
        pending.append((now, bytes))
        tapBuffer.append(contentsOf: bytes)
        if tapBuffer.count > 1_000_000 {
            tapBuffer.removeFirst(tapBuffer.count - 1_000_000)
        }
        lock.unlock()
    }

    func drainPending() -> [(Date, [UInt8])] {
        lock.lock()
        let out = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    /// Sucht `pattern` im Skript-Puffer; bei Treffer wird alles bis einschließlich
    /// des Treffers entnommen und zurückgegeben.
    func tapWait(for pattern: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !pattern.isEmpty, let r = tapBuffer.range(of: pattern) else { return nil }
        let consumed = tapBuffer.subdata(in: tapBuffer.startIndex..<r.upperBound)
        tapBuffer.removeSubrange(tapBuffer.startIndex..<r.upperBound)
        return consumed
    }

    func tapTakeAll() -> Data {
        lock.lock()
        let d = tapBuffer
        tapBuffer = Data()
        lock.unlock()
        return d
    }

    func tapClear() {
        lock.lock()
        tapBuffer = Data()
        lock.unlock()
    }
}

// MARK: - Einstellungen

struct PrefsData: Codable, Equatable {
    var inputFormat: InputFormat = .ascii
    var lineEnding: LineEnding = .none
    var rxLineMode: RxLineMode = .lf
    var idleGapMs = 50
    var wrapBytes = 0                 // 0 = kein erzwungener Umbruch (intern max. 4096)

    // Formate der Empfangsansicht ("Ausgabe") und der Sendeansicht ("Eingabe")
    var outAscii = true
    var outHex = true
    var outDec = false
    var outBin = false
    var inAscii = true
    var inHex = true
    var inDec = false
    var inBin = false

    var cellView = false              // false = lesbare Textansicht, true = HTerm-Zellen
    var fontSize = 13.0               // Schriftgröße der Textansicht
    var showControl = true            // CR/LF am Zeilenende in den Zellen zeigen
    var showTimestamps = false
    var showMessages = true           // Status-/Fehlermeldungen im Empfangsfenster
    var autoScroll = true
    var autoReconnect = true
    var countByte = 13                // Byte-Wert, dessen Vorkommen gezählt werden
    var clearAtEnabled = false
    var clearAtBytes = 10_000
    var history: [String] = []        // Befehls-Historie (bleibt über Neustarts erhalten)
    var scriptSource = ScriptSamples.basic

    var outFormats: [DisplayFormat] { Self.formats(outAscii, outHex, outDec, outBin) }
    var inFormats: [DisplayFormat] { Self.formats(inAscii, inHex, inDec, inBin) }

    private static func formats(_ a: Bool, _ h: Bool, _ d: Bool, _ b: Bool) -> [DisplayFormat] {
        var r = [DisplayFormat]()
        if a { r.append(.ascii) }
        if h { r.append(.hex) }
        if d { r.append(.dec) }
        if b { r.append(.bin) }
        return r
    }
}

@MainActor
final class Prefs: ObservableObject {
    private static let key = "hardterm.prefs.v2"

    @Published var data: PrefsData {
        didSet { scheduleSave() }
    }
    private var saveWork: DispatchWorkItem?

    init() {
        if let raw = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(PrefsData.self, from: raw) {
            data = decoded
        } else {
            data = PrefsData()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func saveNow() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: Self.key)
        }
    }

}

// MARK: - Tabs / Verbindungsarten

enum ConnKind: String, Codable, CaseIterable, Identifiable {
    case serial = "Seriell"
    case telnet = "Telnet"
    case ssh = "SSH"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .serial: return "cable.connector"
        case .telnet: return "network"
        case .ssh: return "lock.shield"
        }
    }

    var defaultPort: Int {
        switch self {
        case .serial: return 0
        case .telnet: return 23
        case .ssh: return 22
        }
    }
}

/// Verbindungseinstellungen eines Tabs (werden pro Tab gespeichert).
struct TabConfig: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: ConnKind = .serial
    var serial = PortConfig()
    var host = ""
    var port = 23
    var user = ""
    var keyFile = ""
    var extraArgs = ""

    init(kind: ConnKind = .serial) {
        self.kind = kind
        if kind != .serial { port = kind.defaultPort }
    }
}

// MARK: - Beispielskripte

enum ScriptSamples {
    static let basic = #"""
// Hardterm-Skript (JavaScript)
// API:  send(text)  sendHex("AA BB")  sendBytes([1,2,3])  sleep(ms)
//       waitFor(text, timeoutMs) -> empfangener Text oder null
//       flush()  received()  log(text)  clear()  connected()
flush();
send("AT\r\n");
const antwort = waitFor("OK", 2000);
if (antwort === null) {
  log("Keine Antwort (Timeout)");
} else {
  log("Antwort: " + JSON.stringify(antwort));
}
"""#

    static let loop = #"""
// Zyklisch senden und Antwort prüfen
for (let i = 0; i < 10; i++) {
  flush();
  send("PING " + i + "\n");
  const r = waitFor("PONG", 500);
  log(i + ": " + (r === null ? "Timeout" : "ok"));
  sleep(200);
}
"""#

    static let hex = #"""
// Binäres Telegramm senden, Antwort lesen
flush();
sendHex("02 10 00 03");
sleep(300);
const rx = received();
log("Empfangen: " + rx.length + " Zeichen");
"""#
}
