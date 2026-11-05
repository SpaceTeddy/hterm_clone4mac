import SwiftUI
import AppKit

/// Zeichnet einen TermBuffer und wandelt Tastatureingaben in Terminal-Bytes um.
@MainActor
final class TerminalNSView: NSView, @preconcurrency NSTextInputClient {
    var buffer: TermBuffer! {
        didSet {
            buffer?.onChange = { [weak self] in self?.bufferChanged() }
        }
    }
    var onSend: (@MainActor ([UInt8]) -> Void)?
    var onResize: (@MainActor (Int, Int) -> Void)?

    var fontSize: CGFloat = 13 {
        didSet {
            guard fontSize != oldValue else { return }
            updateMetrics()
            lastCols = 0
            needsLayout = true
            needsDisplay = true
        }
    }

    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var cellW: CGFloat = 8
    private var cellH: CGFloat = 16
    private var baseline: CGFloat = 12
    private var scrollOffset = 0           // Zeilen oberhalb des Bildschirms (Scrollback)
    private var scrollAccum: CGFloat = 0
    private var selStart: (col: Int, row: Int)?
    private var selEnd: (col: Int, row: Int)?
    private var lastCols = 0
    private var lastRows = 0

    private var defaultFG = NSColor(srgbRed: 0.83, green: 0.83, blue: 0.83, alpha: 1)
    private var defaultBG = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
    private var fontFamilySig = ""
    var theme: Appearance? {
        didSet { refreshTheme() }
    }

    private static let ansi: [NSColor] = {
        let v: [(Int, Int, Int)] = [
            (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
            (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
            (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
            (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
        ]
        return v.map { NSColor(srgbRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: 1) }
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        updateMetrics()
    }

    required init?(coder: NSCoder) { fatalError("nicht verwendet") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Der Hintergrund (inkl. Deckkraft) wird von SwiftUI hinter der Ansicht gezeichnet.
    override var isOpaque: Bool { false }

    // MARK: Metrik / Größe

    /// Übernimmt Schriftart, Farben und Transparenz aus den Einstellungen.
    func refreshTheme() {
        guard let a = theme else { return }
        let sig = a.signature + "|\(fontSize)"
        guard sig != fontFamilySig else { return }
        fontFamilySig = sig
        defaultFG = a.textColor
        defaultBG = a.backgroundBase
        updateMetrics()
        lastCols = 0              // Größe neu berechnen (Zellmaße können sich geändert haben)
        needsLayout = true
        needsDisplay = true
    }

    private func updateMetrics() {
        if let a = theme {
            font = a.font(size: fontSize)
            boldFont = a.font(size: fontSize, bold: true)
        } else {
            font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        }
        let adv = ("M" as NSString).size(withAttributes: [.font: font]).width
        cellW = max(1, adv)
        cellH = ceil(font.ascender - font.descender + font.leading)
        baseline = ceil(font.ascender)
    }

    override func layout() {
        super.layout()
        applySize()
    }

    private func applySize() {
        let c = max(20, Int(bounds.width / cellW))
        let r = max(5, Int(bounds.height / cellH))
        guard c != lastCols || r != lastRows, buffer != nil else { return }
        lastCols = c
        lastRows = r
        buffer.resize(cols: c, rows: r)
        selStart = nil
        selEnd = nil
        onResize?(c, r)
    }

    private func bufferChanged() {
        if scrollOffset > 0 {
            scrollOffset = min(scrollOffset, buffer.scrollback.count)
        }
        needsDisplay = true
    }

    // MARK: Zeichnen

    private func color(_ v: Int32, fallback: NSColor, bold: Bool = false) -> NSColor {
        if v < 0 { return fallback }
        if v >= 0x1000000 {
            let r = CGFloat((v >> 16) & 0xFF) / 255
            let g = CGFloat((v >> 8) & 0xFF) / 255
            let b = CGFloat(v & 0xFF) / 255
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        var i = Int(v)
        if bold && i < 8 { i += 8 }
        if i < 16 { return Self.ansi[i] }
        if i < 232 {
            let n = i - 16
            func lvl(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(55 + 40 * x) / 255 }
            return NSColor(srgbRed: lvl(n / 36), green: lvl((n / 6) % 6), blue: lvl(n % 6), alpha: 1)
        }
        let g = CGFloat(8 + 10 * (i - 232)) / 255
        return NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
    }

    private func isSelected(col: Int, row: Int) -> Bool {
        guard let a = selStart, let b = selEnd else { return false }
        let (s, e) = (a.row, a.col) <= (b.row, b.col) ? (a, b) : (b, a)
        if row < s.row || row > e.row { return false }
        if row == s.row && col < s.col { return false }
        if row == e.row && col > e.col { return false }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            NSColor.clear.setFill()
            bounds.fill()
            ctx.restoreGState()
        }
        guard let buf = buffer else { return }

        let firstAbs = max(0, buf.scrollback.count - scrollOffset)
        let focused = window?.firstResponder === self && (window?.isKeyWindow ?? false)

        for line in 0..<buf.rows {
            let abs = firstAbs + line
            guard let cells = buf.row(at: abs) else { continue }
            let y = CGFloat(line) * cellH
            if y > dirtyRect.maxY || y + cellH < dirtyRect.minY { continue }

            // 1. Hintergründe
            var x = 0
            while x < cells.count {
                let (bg, _) = colors(cells[x], sel: isSelected(col: x, row: abs))
                var e = x + 1
                while e < cells.count,
                      colors(cells[e], sel: isSelected(col: e, row: abs)).0 == bg { e += 1 }
                if bg != defaultBG {
                    bg.setFill()
                    NSRect(x: CGFloat(x) * cellW, y: y, width: CGFloat(e - x) * cellW, height: cellH).fill()
                }
                x = e
            }
            // 2. Text (Läufe gleicher Vordergrundfarbe/Schrift)
            x = 0
            while x < cells.count {
                let c = cells[x]
                if c.ch == 32 { x += 1; continue }
                let (_, fg) = colors(c, sel: isSelected(col: x, row: abs))
                let bold = c.attr & TCell.bold != 0
                let under = c.attr & TCell.underline != 0
                var run = String.UnicodeScalarView()
                var e = x
                while e < cells.count {
                    let d = cells[e]
                    let (_, f2) = colors(d, sel: isSelected(col: e, row: abs))
                    if f2 != fg || (d.attr & TCell.bold != 0) != bold || (d.attr & TCell.underline != 0) != under { break }
                    run.append(Unicode.Scalar(d.ch) ?? " ")
                    e += 1
                }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: bold ? boldFont : font,
                    .foregroundColor: fg,
                ]
                if under { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                // zellweise zeichnen, damit das Raster exakt bleibt (auch bei Sonderzeichen)
                var cx = x
                for u in run {
                    if u != " " {
                        NSAttributedString(string: String(u), attributes: attrs)
                            .draw(at: NSPoint(x: CGFloat(cx) * cellW, y: y))
                    }
                    cx += 1
                }
                x = e
            }
        }

        // Cursor
        if buf.cursorVisible && scrollOffset == 0 {
            let r = NSRect(x: CGFloat(buf.cursorX) * cellW, y: CGFloat(buf.cursorY) * cellH,
                           width: cellW, height: cellH)
            if focused {
                defaultFG.withAlphaComponent(0.8).setFill()
                r.fill()
                // Zeichen unter dem Cursor invertiert
                if let cells = buf.row(at: firstAbs + buf.cursorY), buf.cursorX < cells.count,
                   cells[buf.cursorX].ch != 32, let u = Unicode.Scalar(cells[buf.cursorX].ch) {
                    NSAttributedString(string: String(u), attributes: [.font: font, .foregroundColor: defaultBG])
                        .draw(at: r.origin)
                }
            } else {
                defaultFG.setStroke()
                NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
    }

    private func colors(_ c: TCell, sel: Bool) -> (NSColor, NSColor) {
        let bold = c.attr & TCell.bold != 0
        var fg = color(c.fg, fallback: defaultFG, bold: bold)
        var bg = color(c.bg, fallback: defaultBG)
        if c.attr & TCell.dim != 0 { fg = fg.withAlphaComponent(0.6) }
        if c.attr & TCell.inverse != 0 { swap(&fg, &bg) }
        if sel {
            bg = NSColor.selectedTextBackgroundColor
            fg = .white
        }
        return (bg, fg)
    }

    // MARK: Fokus

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: Maus

    private func cellPosition(_ event: NSEvent) -> (col: Int, row: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let col = min(max(0, Int(p.x / cellW)), max(0, buffer.cols - 1))
        let line = min(max(0, Int(p.y / cellH)), max(0, buffer.rows - 1))
        let abs = max(0, buffer.scrollback.count - scrollOffset) + line
        return (col, abs)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = cellPosition(event)
        selStart = p
        selEnd = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        selEnd = cellPosition(event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let a = selStart, let b = selEnd, a.col == b.col, a.row == b.row {
            selStart = nil
            selEnd = nil
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard buffer != nil else { return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellH : event.scrollingDeltaY
        scrollAccum += dy
        let lines = Int(scrollAccum)
        if lines != 0 {
            scrollAccum -= CGFloat(lines)
            scrollOffset = min(max(0, scrollOffset + lines), buffer.scrollback.count)
            needsDisplay = true
        }
    }

    // MARK: Kopieren / Einfügen

    func selectedText() -> String {
        guard let a = selStart, let b = selEnd, let buf = buffer else { return "" }
        let (s, e) = (a.row, a.col) <= (b.row, b.col) ? (a, b) : (b, a)
        var lines = [String]()
        for r in s.row...e.row {
            guard let cells = buf.row(at: r) else { continue }
            let from = r == s.row ? s.col : 0
            let to = r == e.row ? e.col + 1 : cells.count
            lines.append(buf.text(row: cells, from: from, to: to))
        }
        return lines.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        let t = selectedText()
        guard !t.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
        var bytes = Array(s.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r").utf8)
        if buffer.bracketedPaste {
            bytes = Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8)
        }
        send(bytes)
    }

    override func selectAll(_ sender: Any?) {
        guard let buf = buffer else { return }
        selStart = (0, 0)
        selEnd = (buf.cols - 1, buf.totalRows - 1)
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let c = event.charactersIgnoringModifiers else { return false }
        switch c {
        case "c": copy(nil); return true
        case "v": paste(nil); return true
        case "a": selectAll(nil); return true
        default: return false
        }
    }

    // MARK: Tastatur

    private func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if scrollOffset != 0 {
            scrollOffset = 0
            needsDisplay = true
        }
        onSend?(bytes)
    }

    private func csi(_ fin: String, mod: Int, tilde: Int? = nil) -> [UInt8] {
        if let t = tilde {
            return Array((mod > 1 ? "\u{1B}[\(t);\(mod)~" : "\u{1B}[\(t)~").utf8)
        }
        return Array((mod > 1 ? "\u{1B}[1;\(mod)\(fin)" : "\u{1B}[\(fin)").utf8)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        let shift = flags.contains(.shift), alt = flags.contains(.option), ctrl = flags.contains(.control)
        let mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        let app = buffer.appCursorKeys && mod == 1

        func arrow(_ l: String) -> [UInt8] {
            app ? Array("\u{1B}O\(l)".utf8) : csi(l, mod: mod)
        }

        switch event.keyCode {
        case 126: send(arrow("A")); return
        case 125: send(arrow("B")); return
        case 124: send(arrow("C")); return
        case 123: send(arrow("D")); return
        case 115: send(app ? Array("\u{1B}OH".utf8) : csi("H", mod: mod)); return
        case 119: send(app ? Array("\u{1B}OF".utf8) : csi("F", mod: mod)); return
        case 116:
            if shift { pageScroll(+1) } else { send(csi("", mod: mod, tilde: 5)) }
            return
        case 121:
            if shift { pageScroll(-1) } else { send(csi("", mod: mod, tilde: 6)) }
            return
        case 117: send(csi("", mod: mod, tilde: 3)); return
        case 114: send(csi("", mod: mod, tilde: 2)); return        // Einfügen (Help)
        case 51: send([ctrl ? 0x08 : 0x7F]); return                // Backspace
        case 36, 76: send([0x0D]); return                          // Return / Enter
        case 48: send(shift ? Array("\u{1B}[Z".utf8) : [0x09]); return
        case 53: send([0x1B]); return
        case 122: send(Array("\u{1B}OP".utf8)); return
        case 120: send(Array("\u{1B}OQ".utf8)); return
        case 99: send(Array("\u{1B}OR".utf8)); return
        case 118: send(Array("\u{1B}OS".utf8)); return
        case 96: send(csi("", mod: mod, tilde: 15)); return
        case 97: send(csi("", mod: mod, tilde: 17)); return
        case 98: send(csi("", mod: mod, tilde: 18)); return
        case 100: send(csi("", mod: mod, tilde: 19)); return
        case 101: send(csi("", mod: mod, tilde: 20)); return
        case 109: send(csi("", mod: mod, tilde: 21)); return
        case 103: send(csi("", mod: mod, tilde: 23)); return
        case 111: send(csi("", mod: mod, tilde: 24)); return
        default: break
        }

        // Strg+Buchstabe usw. direkt umsetzen
        if ctrl, !alt, let s = event.charactersIgnoringModifiers?.unicodeScalars.first {
            let v = s.value
            if v == 0x20 || v == 0x32 || v == 0x40 { send([0]); return }
            if v >= 0x61 && v <= 0x7A { send([UInt8(v - 0x60)]); return }
            if v >= 0x41 && v <= 0x5A { send([UInt8(v - 0x40)]); return }
            if v == 0x5B { send([0x1B]); return }
            if v == 0x5C { send([0x1C]); return }
            if v == 0x5D { send([0x1D]); return }
            if v == 0x5E || v == 0x36 { send([0x1E]); return }
            if v == 0x5F || v == 0x2D { send([0x1F]); return }
        }
        // Übrige Zeichen (inkl. Tottasten auf der deutschen Tastatur) über das Eingabesystem
        interpretKeyEvents([event])
    }

    private func pageScroll(_ dir: Int) {
        scrollOffset = min(max(0, scrollOffset + dir * max(1, buffer.rows - 1)), buffer.scrollback.count)
        needsDisplay = true
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s: String
        if let a = string as? NSAttributedString { s = a.string } else { s = string as? String ?? "" }
        let filtered = s.unicodeScalars.filter { !(0xF700...0xF8FF).contains($0.value) }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: filtered)
        send(Array(String(view).utf8))
    }

    override func doCommand(by selector: Selector) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let w = window else { return .zero }
        let r = NSRect(x: CGFloat(buffer?.cursorX ?? 0) * cellW, y: CGFloat((buffer?.cursorY ?? 0) + 1) * cellH,
                       width: cellW, height: cellH)
        return w.convertToScreen(convert(r, to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}

/// SwiftUI-Hülle um die Terminalansicht eines Tabs.
struct TerminalPane: NSViewRepresentable {
    @ObservedObject var session: Session
    @ObservedObject var appearance: Appearance
    var active: Bool
    var fontSize: Double

    final class Coordinator {
        var wasActive = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalNSView {
        let v = TerminalNSView(frame: .zero)
        v.fontSize = CGFloat(fontSize)
        v.theme = appearance
        v.buffer = session.term
        let s = session
        v.onSend = { bytes in s.sendRaw(bytes) }
        v.onResize = { c, r in s.terminalResized(cols: c, rows: r) }
        return v
    }

    func updateNSView(_ v: TerminalNSView, context: Context) {
        v.fontSize = CGFloat(fontSize)
        v.refreshTheme()
        if active && !context.coordinator.wasActive {
            DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        }
        context.coordinator.wasActive = active
    }
}
