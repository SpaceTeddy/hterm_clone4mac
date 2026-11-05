import Foundation
import JavaScriptCore

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Alles, was das Skript vom Rest der App braucht. Alle Closures sind thread-sicher.
struct ScriptHost: Sendable {
    let hub: RxHub
    let send: @Sendable ([UInt8]) -> Void
    let log: @Sendable (String) -> Void
    let clearScreen: @Sendable () -> Void
}

/// Führt Skripte in JavaScriptCore auf einem eigenen Thread aus.
/// Blockierende Funktionen (sleep, waitFor) sind dadurch im Skript ganz normal nutzbar.
final class ScriptRunner {
    private var cancel = CancelFlag()

    func run(source: String, host: ScriptHost, onFinish: @escaping @Sendable () -> Void) {
        let flag = CancelFlag()
        cancel = flag
        let thread = Thread {
            Self.execute(source: source, host: host, flag: flag)
            onFinish()
        }
        thread.stackSize = 4 << 20
        thread.start()
    }

    func stop() {
        cancel.set()
    }

    private static func execute(source: String, host: ScriptHost, flag: CancelFlag) {
        guard let ctx = JSContext() else {
            host.log(L("Skript-Engine konnte nicht gestartet werden"))
            return
        }

        ctx.exceptionHandler = { _, exc in
            if flag.isSet { return }
            host.log("⚠︎ " + (exc?.toString() ?? L("Unbekannter Fehler")))
        }

        func abortScript() {
            if let c = JSContext.current() {
                c.exception = JSValue(newErrorFromMessage: L("Abgebrochen"), in: c)
            }
        }

        let sendFn: @convention(block) (String) -> Void = { s in
            host.send(Array(s.utf8))
        }
        let sendHexFn: @convention(block) (String) -> Void = { s in
            do {
                host.send(try Fmt.parse(s, as: .hex))
            } catch {
                host.log("⚠︎ sendHex: \(error.localizedDescription)")
            }
        }
        let sendBytesFn: @convention(block) (JSValue) -> Void = { v in
            if let arr = v.toArray() as? [NSNumber] {
                host.send(arr.map { UInt8(truncatingIfNeeded: $0.intValue) })
            }
        }
        let sleepFn: @convention(block) (Double) -> Void = { ms in
            let end = Date().addingTimeInterval(max(0, ms) / 1000)
            while Date() < end {
                if flag.isSet { abortScript(); return }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        let waitForFn: @convention(block) (String, JSValue) -> Any = { pattern, timeout in
            let ms = timeout.isNumber ? timeout.toDouble() : 5000
            let needle = Data(pattern.utf8)
            let end = Date().addingTimeInterval(max(0, ms) / 1000)
            while true {
                if flag.isSet { abortScript(); return NSNull() }
                if let d = host.hub.tapWait(for: needle) {
                    return String(decoding: d, as: UTF8.self)
                }
                if Date() >= end { return NSNull() }
                Thread.sleep(forTimeInterval: 0.003)
            }
        }
        let receivedFn: @convention(block) () -> String = {
            String(decoding: host.hub.tapTakeAll(), as: UTF8.self)
        }
        let flushFn: @convention(block) () -> Void = {
            host.hub.tapClear()
        }
        let logFn: @convention(block) (JSValue) -> Void = { v in
            host.log(v.toString() ?? "")
        }
        let clearFn: @convention(block) () -> Void = {
            host.clearScreen()
        }
        let connectedFn: @convention(block) () -> Bool = {
            host.hub.connected
        }

        func bind(_ name: String, _ fn: Any) {
            ctx.setObject(fn, forKeyedSubscript: name as NSString)
        }
        bind("send", sendFn)
        bind("sendHex", sendHexFn)
        bind("sendBytes", sendBytesFn)
        bind("sleep", sleepFn)
        bind("waitFor", waitForFn)
        bind("received", receivedFn)
        bind("flush", flushFn)
        bind("log", logFn)
        bind("clear", clearFn)
        bind("connected", connectedFn)
        _ = ctx.evaluateScript("""
        var console = { log: function() { log(Array.prototype.join.call(arguments, ' ')); } };
        var print = log;
        """)

        host.log("▶ " + L("Skript gestartet"))
        _ = ctx.evaluateScript(source)
        host.log("■ " + (flag.isSet ? L("Skript abgebrochen") : L("Skript beendet")))
    }
}
