import SwiftUI

/// Darstellung wie bei HTerm: jedes Byte ist eine Zelle, pro aktiviertem Format eine Zeile
/// (ASCII = cyan, Hex = lavendel, Dezimal = rosa, Binär = grün).
enum CellMetrics {
    static let fontSize: CGFloat = 12

    static let charWidth: CGFloat = {
        let f = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: f]).width
    }()

    /// Breite des Zelleninhalts in Zeichen (richtet sich nach dem breitesten aktiven Format).
    static func contentWidth(_ formats: [DisplayFormat]) -> Int {
        var w = 2
        if formats.contains(.dec) { w = max(w, 3) }
        if formats.contains(.bin) { w = max(w, 8) }
        return w
    }

    static func color(_ f: DisplayFormat) -> Color {
        switch f {
        case .ascii: return Color(red: 0.75, green: 1.00, blue: 1.00)
        case .hex: return Color(red: 0.78, green: 0.78, blue: 1.00)
        case .dec: return Color(red: 1.00, green: 0.78, blue: 0.78)
        case .bin: return Color(red: 0.78, green: 1.00, blue: 0.78)
        }
    }

    static func asciiCell(_ b: UInt8) -> String {
        switch b {
        case 13: return "\\r"
        case 10: return "\\n"
        case 9: return "\\t"
        case 0: return "\\0"
        case 0x20...0x7E: return String(UnicodeScalar(b))
        default: return "·"
        }
    }

    static func cell(_ b: UInt8, _ f: DisplayFormat, width: Int) -> String {
        let raw: String
        switch f {
        case .ascii:
            raw = asciiCell(b)
        case .hex:
            raw = String(format: "%02X", b)
        case .dec:
            raw = String(format: "%03d", Int(b))
        case .bin:
            let s = String(b, radix: 2)
            raw = String(repeating: "0", count: 8 - s.count) + s
        }
        let pad = max(0, width - raw.count)
        let left = pad / 2
        return String(repeating: " ", count: left) + raw + String(repeating: " ", count: pad - left)
    }

    /// Eine Zeile aus farbigen Zellen, getrennt durch eine ungefärbte Lücke.
    static func row(_ bytes: ArraySlice<UInt8>, _ f: DisplayFormat, width: Int) -> AttributedString {
        var out = AttributedString()
        var first = true
        let bg: Color = color(f)
        let fg: Color = Color.black
        for b in bytes {
            if !first { out += AttributedString(" ") }
            first = false
            var a = AttributedString(" " + cell(b, f, width: width) + " ")
            a.backgroundColor = bg
            a.foregroundColor = fg
            out += a
        }
        return out
    }
}

/// Eine Empfangs-/Sendezeile (bis zum Zeilenende) als umbrechende Zellenblöcke.
struct LineGroup: View {
    @EnvironmentObject var session: Session
    let line: Line
    let formats: [DisplayFormat]
    let columns: Int
    let width: Int
    let showTime: Bool
    let showControl: Bool

    var body: some View {
        if line.dir == .info {
            Text(verbatim: infoText)
                .font(.system(size: CellMetrics.fontSize, design: .monospaced))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        } else {
            let bytes = shownBytes
            if !bytes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if showTime {
                        Text(session.timeString(line.time))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(starts(for: bytes.count), id: \.self) { s in
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(formats) { f in
                                Text(CellMetrics.row(bytes[s..<min(s + columns, bytes.count)], f, width: width))
                                    .font(.system(size: CellMetrics.fontSize, design: .monospaced))
                                    .fixedSize()
                            }
                        }
                    }
                }
                .contextMenu {
                    Button("Zeile kopieren als ASCII") { Panels.copy(Fmt.render(line.bytes, as: .ascii)) }
                    Button("Zeile kopieren als Hex") { Panels.copy(Fmt.render(line.bytes, as: .hex)) }
                    Button("Zeile kopieren als Dezimal") { Panels.copy(Fmt.render(line.bytes, as: .dec)) }
                    Button("Zeile kopieren als Binär") { Panels.copy(Fmt.render(line.bytes, as: .bin)) }
                }
            }
        }
    }

    private var infoText: String {
        let t = String(decoding: line.bytes, as: UTF8.self)
        return showTime ? session.timeString(line.time) + "  " + t : t
    }

    private var shownBytes: [UInt8] {
        var b = line.bytes
        if !showControl {
            while let l = b.last, l == 10 || l == 13 { b.removeLast() }
        }
        return b
    }

    private func starts(for count: Int) -> [Int] {
        Array(stride(from: 0, to: count, by: max(1, columns)))
    }
}

/// Scrollbare Fläche mit Zellenzeilen; bricht passend zur Breite um.
struct CellPane: View {
    @EnvironmentObject var prefs: Prefs
    let lines: [Line]
    let formats: [DisplayFormat]
    let revision: Int

    var body: some View {
        GeometryReader { geo in
            let width = CellMetrics.contentWidth(formats)
            let cellPoints = CGFloat(width + 3) * CellMetrics.charWidth
            let columns = max(1, Int((geo.size.width - 28) / cellPoints))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in
                            LineGroup(line: line,
                                      formats: formats,
                                      columns: columns,
                                      width: width,
                                      showTime: prefs.data.showTimestamps,
                                      showControl: prefs.data.showControl)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: revision) {
                    if prefs.data.autoScroll, let last = lines.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}
