import SwiftUI

/// Lesbare Textansicht: normale Zeilen, markier- und kopierbar, ⌘F-Suche, ANSI-Farben.
/// Ist ein NSTextView, an den nur Neues angehängt wird – dadurch auch bei schnellem Datenstrom flüssig.
struct LogTextView: NSViewRepresentable {
    let lines: [Line]
    let formats: [DisplayFormat]
    let revision: Int
    let fontSize: CGFloat
    let showTime: Bool
    let autoScroll: Bool
    let signature: String
    let appearance: Appearance

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        // Hintergrund und Deckkraft zeichnet SwiftUI hinter der Ansicht
        tv.drawsBackground = false
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        scroll.hasVerticalScroller = true
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        private var signature = ""
        private var lastRevision = -1
        private var firstId: Int?
        private var lastId: Int?
        private var lastStart = 0

        private static let timeFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        func update(_ v: LogTextView) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let sig = "\(v.signature)|\(v.formats.map { $0.rawValue }.joined())|\(v.showTime)|\(Int(v.fontSize))|\(v.appearance.signature)"
            if sig == signature && v.revision == lastRevision { return }

            var rebuild = sig != signature
            var startIndex = 0
            if !rebuild, let lid = lastId {
                if v.lines.first?.id != firstId {
                    rebuild = true                      // vorne wurde gekürzt
                } else if let idx = v.lines.lastIndex(where: { $0.id == lid }) {
                    startIndex = idx                    // letzte Zeile kann gewachsen sein
                } else {
                    rebuild = true                      // geleert oder gefiltert
                }
            }

            let base: Int
            if rebuild {
                storage.setAttributedString(NSAttributedString())
                base = 0
                startIndex = 0
            } else {
                base = min(lastStart, storage.length)
            }

            let font = v.appearance.font(size: v.fontSize)
            let attr = NSMutableAttributedString()
            var newLastStart = base
            if startIndex < v.lines.count {
                for i in startIndex..<v.lines.count {
                    if i == v.lines.count - 1 { newLastStart = base + attr.length }
                    attr.append(Self.render(v.lines[i], v, font))
                }
            }

            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: base, length: storage.length - base), with: attr)
            storage.endEditing()

            signature = sig
            lastRevision = v.revision
            firstId = v.lines.first?.id
            lastId = v.lines.last?.id
            lastStart = v.lines.isEmpty ? 0 : newLastStart

            if v.autoScroll { tv.scrollToEndOfDocument(nil) }
        }

        private static func render(_ line: Line, _ v: LogTextView, _ font: NSFont) -> NSAttributedString {
            let out = NSMutableAttributedString()
            let color: NSColor
            switch line.dir {
            case .tx: color = .systemBlue
            case .info: color = .systemOrange
            case .rx: color = v.appearance.textColor
            }
            let dim: NSColor = v.appearance.textColor.withAlphaComponent(0.6)
            let small = v.appearance.font(size: max(8, v.fontSize - 1))

            func add(_ s: String, _ c: NSColor, _ f: NSFont) {
                out.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c]))
            }

            var needTime = v.showTime
            let time = timeFmt.string(from: line.time) + "  "

            if line.dir == .info {
                if needTime { add(time, dim, font) }
                add(String(decoding: line.bytes, as: UTF8.self) + "\n", color, font)
                return out
            }

            for f in v.formats {
                if needTime {
                    add(time, dim, font)
                    needTime = false
                }
                if f == .ascii {
                    out.append(Ansi.attributed(line.bytes, base: color, font: font))
                    add("\n", color, font)
                } else {
                    let label = f.rawValue.lowercased().padding(toLength: 4, withPad: " ", startingAt: 0)
                    add("  " + label + " " + Fmt.render(line.bytes, as: f) + "\n", dim, small)
                }
            }
            return out
        }
    }
}

/// Minimaler ANSI-Parser: SGR-Farben (30–37, 90–97, 0, 1, 22, 39), übrige Escape-Sequenzen werden verworfen.
enum Ansi {
    static func attributed(_ bytes: [UInt8], base: NSColor, font: NSFont) -> NSAttributedString {
        var b = bytes
        while let l = b.last, l == 10 || l == 13 { b.removeLast() }
        let scalars = Array(String(decoding: b, as: UTF8.self).unicodeScalars)

        let out = NSMutableAttributedString()
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        var color = base
        var bold = false
        var buf = ""

        func flush() {
            guard !buf.isEmpty else { return }
            out.append(NSAttributedString(string: buf,
                                          attributes: [.font: bold ? boldFont : font,
                                                       .foregroundColor: color]))
            buf = ""
        }

        let palette: [NSColor] = [.systemGray, .systemRed, .systemGreen, .systemYellow,
                                  .systemBlue, .systemPink, .systemTeal, base]

        func apply(_ params: String) {
            let codes = params.split(separator: ";", omittingEmptySubsequences: false)
                .map { Int($0) ?? 0 }
            var k = 0
            while k < codes.count {
                let c = codes[k]
                switch c {
                case 0: color = base; bold = false
                case 1: bold = true
                case 22: bold = false
                case 30...37: color = palette[c - 30]
                case 90...97: color = palette[c - 90]
                case 39: color = base
                case 38, 48:
                    // erweiterte Farben überspringen (38;5;n bzw. 38;2;r;g;b)
                    if k + 1 < codes.count { k += codes[k + 1] == 5 ? 2 : 4 }
                default: break
                }
                k += 1
            }
        }

        var i = 0
        while i < scalars.count {
            let u = scalars[i]
            if u.value == 0x1B, i + 1 < scalars.count, scalars[i + 1] == "[" {
                var j = i + 2
                var params = ""
                while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                    params.unicodeScalars.append(scalars[j])
                    j += 1
                }
                if j < scalars.count {
                    if scalars[j] == "m" {
                        flush()
                        apply(params)
                    }
                    i = j + 1
                } else {
                    i = scalars.count
                }
                continue
            }
            if u.value == 0x1B, i + 1 < scalars.count {
                let n = scalars[i + 1]
                if n == "]" {
                    // OSC (z. B. Fenstertitel): bis BEL oder ESC \ verwerfen
                    var j = i + 2
                    while j < scalars.count, scalars[j].value != 0x07,
                          !(scalars[j].value == 0x1B && j + 1 < scalars.count && scalars[j + 1] == "\\") {
                        j += 1
                    }
                    if j < scalars.count, scalars[j].value == 0x07 {
                        i = j + 1
                    } else {
                        i = min(scalars.count, j + 2)
                    }
                } else if n == "(" || n == ")" {
                    i = min(scalars.count, i + 3)       // Zeichensatzwahl
                } else {
                    i += 2                              // sonstige Zwei-Zeichen-Folgen
                }
                continue
            }
            if (u.value < 0x20 && u.value != 9) || u.value == 0x7F {
                buf.append("·")
            } else {
                buf.unicodeScalars.append(u)
            }
            i += 1
        }
        flush()
        return out
    }
}

/// Wählt je nach Einstellung Textansicht oder HTerm-Zellenansicht.
struct DataPane: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var appearance: Appearance
    @EnvironmentObject var workspace: Workspace
    let lines: [Line]
    let formats: [DisplayFormat]
    var signature: String = ""

    var body: some View {
        if prefs.data.cellView {
            CellPane(lines: lines, formats: formats, revision: session.revision)
        } else {
            LogTextView(lines: lines,
                        formats: formats,
                        revision: session.revision,
                        fontSize: CGFloat(prefs.data.fontSize),
                        showTime: prefs.data.showTimestamps,
                        autoScroll: prefs.data.autoScroll,
                        signature: signature,
                        appearance: appearance)
                .transparentPane(active: workspace.selectedId == session.id)
        }
    }
}
