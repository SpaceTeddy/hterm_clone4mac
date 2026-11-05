import Foundation

/// Eine Zelle des Terminalrasters. Farben: -1 = Standard, 0...255 = Palette, 0x1000000|RGB = TrueColor.
struct TCell: Equatable {
    var ch: UInt32 = 32
    var fg: Int32 = -1
    var bg: Int32 = -1
    var attr: UInt8 = 0

    static let bold: UInt8 = 1
    static let underline: UInt8 = 2
    static let inverse: UInt8 = 4
    static let dim: UInt8 = 8
    static let italic: UInt8 = 16
}

/// Kompakter VT100/xterm-Emulator: Cursor, SGR (16/256/TrueColor), Löschen, Scrollbereiche,
/// Alternate Screen (vim, top, less), Scrollback. Läuft komplett im Hauptthread.
@MainActor
final class TermBuffer {
    private(set) var cols = 80
    private(set) var rows = 24
    private(set) var screen: [[TCell]] = []
    private(set) var scrollback: [[TCell]] = []
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var cursorVisible = true
    private(set) var altScreen = false
    private(set) var appCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var title = ""

    /// Antworten an den Server (Cursorposition, Geräteabfrage).
    var onReply: (@MainActor ([UInt8]) -> Void)?
    /// Inhalt hat sich geändert → neu zeichnen.
    var onChange: (@MainActor () -> Void)?

    private static let maxScrollback = 5000

    private var pen = TCell()
    private var wrapPending = false
    private var autowrap = true
    private var originMode = false
    private var top = 0
    private var bottom = 23
    private var tabs = Set<Int>()
    private var savedCursor = (x: 0, y: 0, pen: TCell())
    private var savedMain: (screen: [[TCell]], x: Int, y: Int)?

    // Parser
    private enum PState { case ground, esc, csi, osc, skip1 }
    private var pstate = PState.ground
    private var csiBuf = [UInt8]()
    private var oscBuf = [UInt8]()
    private var utf8Need = 0
    private var utf8Acc: UInt32 = 0

    init() {
        screen = Array(repeating: blankRow(), count: rows)
        bottom = rows - 1
        resetTabs()
    }

    // MARK: Hilfen

    private func blankCell() -> TCell {
        var c = TCell()
        c.bg = pen.bg
        return c
    }

    private func blankRow() -> [TCell] {
        Array(repeating: blankCell(), count: cols)
    }

    private func resetTabs() {
        tabs = Set(stride(from: 8, to: max(cols, 9), by: 8))
    }

    /// Ganze Zeile ab Absolutindex (Scrollback + Bildschirm).
    var totalRows: Int { scrollback.count + rows }

    func row(at abs: Int) -> [TCell]? {
        if abs < 0 { return nil }
        if abs < scrollback.count { return scrollback[abs] }
        let i = abs - scrollback.count
        return i < screen.count ? screen[i] : nil
    }

    func text(row r: [TCell], from: Int = 0, to: Int? = nil) -> String {
        let end = min(to ?? r.count, r.count)
        guard from < end else { return "" }
        var s = String.UnicodeScalarView()
        for c in r[from..<end] {
            s.append(Unicode.Scalar(c.ch) ?? " ")
        }
        var str = String(s)
        while str.hasSuffix(" ") { str.removeLast() }
        return str
    }

    func plainText() -> String {
        var lines = scrollback.map { text(row: $0) }
        lines += screen.map { text(row: $0) }
        while let l = lines.last, l.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Zurücksetzen / Größe

    /// Beim Verbinden: Modi zurücksetzen, Inhalt bleibt erhalten.
    func softReset() {
        if altScreen { leaveAlt() }
        pen = TCell()
        autowrap = true
        originMode = false
        appCursorKeys = false
        bracketedPaste = false
        cursorVisible = true
        top = 0
        bottom = rows - 1
        pstate = .ground
        utf8Need = 0
        wrapPending = false
        if cursorX != 0 { feed(Array("\r\n".utf8)) }
        onChange?()
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(2, newCols), nr = max(2, newRows)
        guard nc != cols || nr != rows else { return }
        // Zeilenanzahl
        if nr < rows {
            var drop = rows - nr
            while drop > 0 {
                if cursorY > 0 {
                    let r = screen.removeFirst()
                    if !altScreen { pushScrollback(r) }
                    cursorY -= 1
                } else {
                    screen.removeLast()
                }
                drop -= 1
            }
        } else if nr > rows {
            for _ in 0..<(nr - rows) { screen.append(blankRow()) }
        }
        rows = nr
        // Spaltenanzahl
        if nc != cols {
            for i in 0..<screen.count {
                if nc > screen[i].count {
                    screen[i] += Array(repeating: TCell(), count: nc - screen[i].count)
                } else {
                    screen[i].removeLast(screen[i].count - nc)
                }
            }
            for i in 0..<scrollback.count {
                if scrollback[i].count > nc { scrollback[i].removeLast(scrollback[i].count - nc) }
            }
        }
        cols = nc
        top = 0
        bottom = rows - 1
        cursorX = min(cursorX, cols - 1)
        cursorY = min(max(cursorY, 0), rows - 1)
        wrapPending = false
        resetTabs()
        onChange?()
    }

    private func pushScrollback(_ r: [TCell]) {
        scrollback.append(r)
        if scrollback.count > Self.maxScrollback + 500 {
            scrollback.removeFirst(500)
        }
    }

    // MARK: Eingabe

    func feed(_ bytes: [UInt8]) {
        for b in bytes { process(b) }
        onChange?()
    }

    private func process(_ b: UInt8) {
        switch pstate {
        case .ground:
            ground(b)
        case .esc:
            escape(b)
        case .csi:
            if b == 0x1B {
                pstate = .esc
            } else if b >= 0x40 && b <= 0x7E {
                dispatchCSI(final: b)
                pstate = .ground
            } else if b >= 0x20 && b <= 0x3F {
                if csiBuf.count < 64 { csiBuf.append(b) }
            }
            // Steuerzeichen < 0x20 werden ignoriert
        case .osc:
            if b == 0x07 {
                finishOSC()
                pstate = .ground
            } else if b == 0x1B {
                finishOSC()
                pstate = .esc
            } else if oscBuf.count < 512 {
                oscBuf.append(b)
            }
        case .skip1:
            pstate = .ground
        }
    }

    private func finishOSC() {
        let s = String(decoding: oscBuf, as: UTF8.self)
        if s.hasPrefix("0;") || s.hasPrefix("2;") { title = String(s.dropFirst(2)) }
        oscBuf.removeAll()
    }

    private func ground(_ b: UInt8) {
        if utf8Need > 0 {
            if b & 0xC0 == 0x80 {
                utf8Acc = (utf8Acc << 6) | UInt32(b & 0x3F)
                utf8Need -= 1
                if utf8Need == 0 { put(utf8Acc) }
                return
            }
            utf8Need = 0               // ungültige Folge → neu beginnen
        }
        switch b {
        case 0x1B: pstate = .esc
        case 0x07, 0x00, 0x0E, 0x0F: break
        case 0x08: if cursorX > 0 { cursorX -= 1 }; wrapPending = false
        case 0x09: tab()
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: cursorX = 0; wrapPending = false
        case 0x20...0x7E: put(UInt32(b))
        case 0xC2...0xDF: utf8Need = 1; utf8Acc = UInt32(b & 0x1F)
        case 0xE0...0xEF: utf8Need = 2; utf8Acc = UInt32(b & 0x0F)
        case 0xF0...0xF4: utf8Need = 3; utf8Acc = UInt32(b & 0x07)
        default: break
        }
    }

    private func escape(_ b: UInt8) {
        pstate = .ground
        switch b {
        case UInt8(ascii: "["): csiBuf.removeAll(); pstate = .csi
        case UInt8(ascii: "]"): oscBuf.removeAll(); pstate = .osc
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "#"):
            pstate = .skip1
        case UInt8(ascii: "7"): savedCursor = (cursorX, cursorY, pen)
        case UInt8(ascii: "8"):
            cursorX = min(savedCursor.x, cols - 1)
            cursorY = min(savedCursor.y, rows - 1)
            pen = savedCursor.pen
            wrapPending = false
        case UInt8(ascii: "D"): lineFeed()
        case UInt8(ascii: "E"): cursorX = 0; lineFeed()
        case UInt8(ascii: "M"): reverseIndex()
        case UInt8(ascii: "H"): tabs.insert(cursorX)
        case UInt8(ascii: "c"): fullReset()
        default: break               // =, >, \ usw. ignorieren
        }
    }

    private func fullReset() {
        if altScreen { leaveAlt() }
        pen = TCell()
        autowrap = true
        originMode = false
        appCursorKeys = false
        bracketedPaste = false
        cursorVisible = true
        top = 0
        bottom = rows - 1
        screen = Array(repeating: blankRow(), count: rows)
        cursorX = 0
        cursorY = 0
        wrapPending = false
        resetTabs()
    }

    // MARK: Zeichen / Cursor

    private func put(_ code: UInt32) {
        if wrapPending {
            wrapPending = false
            if autowrap {
                cursorX = 0
                lineFeed()
            }
        }
        var c = pen
        c.ch = code
        screen[cursorY][cursorX] = c
        if cursorX >= cols - 1 {
            wrapPending = true
        } else {
            cursorX += 1
        }
    }

    private func tab() {
        wrapPending = false
        var x = cursorX + 1
        while x < cols - 1 && !tabs.contains(x) { x += 1 }
        cursorX = min(x, cols - 1)
    }

    private func lineFeed() {
        wrapPending = false
        if cursorY == bottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        wrapPending = false
        if cursorY == top {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    private func scrollUp(_ n: Int) {
        let count = min(n, bottom - top + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            let removed = screen.remove(at: top)
            if top == 0 && !altScreen { pushScrollback(removed) }
            screen.insert(blankRow(), at: bottom)
        }
    }

    private func scrollDown(_ n: Int) {
        let count = min(n, bottom - top + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            screen.remove(at: bottom)
            screen.insert(blankRow(), at: top)
        }
    }

    // MARK: Alternate Screen

    private func enterAlt(save: Bool) {
        guard !altScreen else { return }
        savedMain = (screen, cursorX, cursorY)
        altScreen = true
        screen = Array(repeating: blankRow(), count: rows)
        cursorX = 0
        cursorY = 0
        top = 0
        bottom = rows - 1
        wrapPending = false
    }

    private func leaveAlt() {
        guard altScreen else { return }
        altScreen = false
        if let s = savedMain {
            screen = s.screen
            // Größe kann sich inzwischen geändert haben
            if screen.count > rows { screen.removeFirst(screen.count - rows) }
            while screen.count < rows { screen.append(blankRow()) }
            for i in 0..<screen.count {
                if screen[i].count > cols { screen[i].removeLast(screen[i].count - cols) }
                if screen[i].count < cols { screen[i] += Array(repeating: TCell(), count: cols - screen[i].count) }
            }
            cursorX = min(s.x, cols - 1)
            cursorY = min(s.y, rows - 1)
        }
        savedMain = nil
        top = 0
        bottom = rows - 1
        wrapPending = false
    }

    // MARK: CSI

    private func dispatchCSI(final f: UInt8) {
        var priv = false
        var digits = [UInt8]()
        for b in csiBuf {
            if b == UInt8(ascii: "?") || b == UInt8(ascii: ">") || b == UInt8(ascii: "=") || b == UInt8(ascii: "<") {
                priv = true
            } else if b >= 0x30 && b <= 0x3B {
                digits.append(b)
            } else {
                // Zwischenzeichen (z. B. Leerzeichen bei DECSCUSR) → ignorieren
                if f == UInt8(ascii: "q") { return }
            }
        }
        let p: [Int] = String(decoding: digits, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        func arg(_ i: Int, _ def: Int) -> Int {
            i < p.count && p[i] > 0 ? p[i] : def
        }
        let ch = Character(Unicode.Scalar(f))

        if priv {
            if ch == "h" || ch == "l" { setPrivateModes(p, on: ch == "h") }
            return
        }

        switch ch {
        case "A": cursorY = max(top <= cursorY ? top : 0, cursorY - arg(0, 1)); wrapPending = false
        case "B": cursorY = min(cursorY >= top && cursorY <= bottom ? bottom : rows - 1, cursorY + arg(0, 1)); wrapPending = false
        case "C", "a": cursorX = min(cols - 1, cursorX + arg(0, 1)); wrapPending = false
        case "D": cursorX = max(0, cursorX - arg(0, 1)); wrapPending = false
        case "E": cursorX = 0; cursorY = min(rows - 1, cursorY + arg(0, 1)); wrapPending = false
        case "F": cursorX = 0; cursorY = max(0, cursorY - arg(0, 1)); wrapPending = false
        case "G", "`": cursorX = min(cols - 1, arg(0, 1) - 1); wrapPending = false
        case "H", "f":
            let r = arg(0, 1) - 1
            cursorY = originMode ? min(bottom, top + r) : min(rows - 1, r)
            cursorX = min(cols - 1, arg(1, 1) - 1)
            wrapPending = false
        case "d":
            let r = arg(0, 1) - 1
            cursorY = originMode ? min(bottom, top + r) : min(rows - 1, r)
            wrapPending = false
        case "J": eraseDisplay(p.first ?? 0)
        case "K": eraseLine(p.first ?? 0)
        case "L": insertLines(arg(0, 1))
        case "M": deleteLines(arg(0, 1))
        case "@": insertChars(arg(0, 1))
        case "P": deleteChars(arg(0, 1))
        case "X":
            let n = min(arg(0, 1), cols - cursorX)
            for i in 0..<n { screen[cursorY][cursorX + i] = blankCell() }
        case "S": scrollUp(arg(0, 1))
        case "T": scrollDown(arg(0, 1))
        case "m": sgr(p.isEmpty ? [0] : p)
        case "r":
            let t = arg(0, 1) - 1
            let b = (p.count > 1 && p[1] > 0 ? p[1] : rows) - 1
            if t < b && b < rows {
                top = t
                bottom = b
            } else {
                top = 0
                bottom = rows - 1
            }
            cursorX = 0
            cursorY = originMode ? top : 0
            wrapPending = false
        case "s": savedCursor = (cursorX, cursorY, pen)
        case "u":
            cursorX = min(savedCursor.x, cols - 1)
            cursorY = min(savedCursor.y, rows - 1)
            wrapPending = false
        case "g":
            if (p.first ?? 0) == 3 { tabs.removeAll() } else { tabs.remove(cursorX) }
        case "n":
            if (p.first ?? 0) == 6 {
                onReply?(Array("\u{1B}[\(cursorY + 1);\(cursorX + 1)R".utf8))
            } else if (p.first ?? 0) == 5 {
                onReply?(Array("\u{1B}[0n".utf8))
            }
        case "c":
            onReply?(Array("\u{1B}[?1;2c".utf8))
        default:
            break
        }
    }

    private func setPrivateModes(_ modes: [Int], on: Bool) {
        for m in modes {
            switch m {
            case 1: appCursorKeys = on
            case 6: originMode = on; cursorX = 0; cursorY = on ? top : 0
            case 7: autowrap = on
            case 25: cursorVisible = on
            case 47, 1047, 1049:
                if on { enterAlt(save: m == 1049) } else { leaveAlt() }
            case 2004: bracketedPaste = on
            default: break
            }
        }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            if cursorY + 1 < rows {
                for y in (cursorY + 1)..<rows { screen[y] = blankRow() }
            }
        case 1:
            for y in 0..<cursorY { screen[y] = blankRow() }
            eraseLine(1)
        case 2:
            for y in 0..<rows { screen[y] = blankRow() }
        case 3:
            scrollback.removeAll()
        default:
            break
        }
    }

    private func eraseLine(_ mode: Int) {
        let blank = blankCell()
        switch mode {
        case 0: for x in cursorX..<cols { screen[cursorY][x] = blank }
        case 1: for x in 0...cursorX { screen[cursorY][x] = blank }
        case 2: screen[cursorY] = blankRow()
        default: break
        }
    }

    private func insertLines(_ n: Int) {
        guard cursorY >= top && cursorY <= bottom else { return }
        for _ in 0..<min(n, bottom - cursorY + 1) {
            screen.remove(at: bottom)
            screen.insert(blankRow(), at: cursorY)
        }
        cursorX = 0
        wrapPending = false
    }

    private func deleteLines(_ n: Int) {
        guard cursorY >= top && cursorY <= bottom else { return }
        for _ in 0..<min(n, bottom - cursorY + 1) {
            screen.remove(at: cursorY)
            screen.insert(blankRow(), at: bottom)
        }
        cursorX = 0
        wrapPending = false
    }

    private func insertChars(_ n: Int) {
        let k = min(n, cols - cursorX)
        screen[cursorY].removeLast(k)
        screen[cursorY].insert(contentsOf: Array(repeating: blankCell(), count: k), at: cursorX)
    }

    private func deleteChars(_ n: Int) {
        let k = min(n, cols - cursorX)
        screen[cursorY].removeSubrange(cursorX..<(cursorX + k))
        screen[cursorY].append(contentsOf: Array(repeating: blankCell(), count: k))
    }

    private func sgr(_ codes: [Int]) {
        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: pen = TCell()
            case 1: pen.attr |= TCell.bold
            case 2: pen.attr |= TCell.dim
            case 3: pen.attr |= TCell.italic
            case 4: pen.attr |= TCell.underline
            case 7: pen.attr |= TCell.inverse
            case 22: pen.attr &= ~(TCell.bold | TCell.dim)
            case 23: pen.attr &= ~TCell.italic
            case 24: pen.attr &= ~TCell.underline
            case 27: pen.attr &= ~TCell.inverse
            case 30...37: pen.fg = Int32(c - 30)
            case 39: pen.fg = -1
            case 40...47: pen.bg = Int32(c - 40)
            case 49: pen.bg = -1
            case 90...97: pen.fg = Int32(c - 90 + 8)
            case 100...107: pen.bg = Int32(c - 100 + 8)
            case 38, 48:
                var color: Int32?
                if i + 1 < codes.count {
                    if codes[i + 1] == 5, i + 2 < codes.count {
                        color = Int32(min(255, max(0, codes[i + 2])))
                        i += 2
                    } else if codes[i + 1] == 2, i + 4 < codes.count {
                        let r = min(255, max(0, codes[i + 2]))
                        let g = min(255, max(0, codes[i + 3]))
                        let b = min(255, max(0, codes[i + 4]))
                        color = Int32(0x1000000 | (r << 16) | (g << 8) | b)
                        i += 4
                    }
                }
                if let color {
                    if c == 38 { pen.fg = color } else { pen.bg = color }
                }
            default: break
            }
            i += 1
        }
    }
}
