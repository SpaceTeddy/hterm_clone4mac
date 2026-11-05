import Foundation

enum DisplayFormat: String, CaseIterable, Codable, Identifiable {
    case ascii = "ASCII", hex = "Hex", dec = "Dez", bin = "Bin"
    var id: String { rawValue }
}

typealias InputFormat = DisplayFormat

enum LineEnding: String, CaseIterable, Codable, Identifiable {
    case none = "Kein", lf = "LF", cr = "CR", crlf = "CR+LF"
    var id: String { rawValue }
    var bytes: [UInt8] {
        switch self {
        case .none: return []
        case .lf: return [10]
        case .cr: return [13]
        case .crlf: return [13, 10]
        }
    }
}

/// Wann eine empfangene Zeile als abgeschlossen gilt.
enum RxLineMode: String, CaseIterable, Codable, Identifiable {
    case lf = "LF", cr = "CR", crlf = "CR+LF", idle = "Zeitlücke"
    var id: String { rawValue }
}

enum ParseError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let m) = self { return m }
        return nil
    }
}

enum Fmt {
    // MARK: Anzeige

    static func render(_ bytes: [UInt8], as format: DisplayFormat) -> String {
        switch format {
        case .ascii:
            var b = bytes
            while let l = b.last, l == 10 || l == 13 { b.removeLast() }
            let s = String(decoding: b, as: UTF8.self)
            var out = ""
            for u in s.unicodeScalars {
                if (u.value < 0x20 && u.value != 9) || u.value == 0x7F {
                    out.append("·")
                } else {
                    out.unicodeScalars.append(u)
                }
            }
            return out
        case .hex:
            return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .dec:
            return bytes.map { String($0) }.joined(separator: " ")
        case .bin:
            return bytes.map { b -> String in
                let s = String(b, radix: 2)
                return String(repeating: "0", count: 8 - s.count) + s
            }.joined(separator: " ")
        }
    }

    // MARK: Eingabe

    static func parse(_ text: String, as format: InputFormat) throws -> [UInt8] {
        switch format {
        case .ascii:
            return unescape(text)

        case .hex:
            var t = text.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            t.removeAll { $0 == " " || $0 == "," || $0 == "\t" || $0 == ":" }
            guard t.count % 2 == 0 else {
                throw ParseError.invalid(L("Hex: ungerade Anzahl an Ziffern"))
            }
            var out = [UInt8]()
            var i = t.startIndex
            while i < t.endIndex {
                let j = t.index(i, offsetBy: 2)
                guard let v = UInt8(t[i..<j], radix: 16) else {
                    throw ParseError.invalid(L("Hex: ungültige Ziffern „%@“", String(t[i..<j])))
                }
                out.append(v)
                i = j
            }
            return out

        case .dec:
            var out = [UInt8]()
            for tok in tokens(text) {
                guard let v = UInt8(tok) else {
                    throw ParseError.invalid(L("Dez: „%@“ ist kein Wert von 0–255", String(tok)))
                }
                out.append(v)
            }
            return out

        case .bin:
            var out = [UInt8]()
            for tok in tokens(text) {
                guard tok.allSatisfy({ $0 == "0" || $0 == "1" }) else {
                    throw ParseError.invalid(L("Bin: „%@“ enthält andere Zeichen als 0/1", String(tok)))
                }
                if tok.count <= 8 {
                    out.append(UInt8(tok, radix: 2) ?? 0)
                } else {
                    guard tok.count % 8 == 0 else {
                        throw ParseError.invalid(L("Bin: Länge muss ein Vielfaches von 8 sein"))
                    }
                    var i = tok.startIndex
                    while i < tok.endIndex {
                        let j = tok.index(i, offsetBy: 8)
                        out.append(UInt8(tok[i..<j], radix: 2) ?? 0)
                        i = j
                    }
                }
            }
            return out
        }
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
    }

    /// ASCII-Eingabe mit Escapes: \n \r \t \0 \\ \xNN
    static func unescape(_ text: String) -> [UInt8] {
        var out = [UInt8]()
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "n": out.append(10); i += 2; continue
                case "r": out.append(13); i += 2; continue
                case "t": out.append(9); i += 2; continue
                case "0": out.append(0); i += 2; continue
                case "\\": out.append(92); i += 2; continue
                case "x":
                    if i + 3 < chars.count,
                       let v = UInt8(String(chars[i + 2...i + 3]), radix: 16) {
                        out.append(v)
                        i += 4
                        continue
                    }
                default: break
                }
            }
            out.append(contentsOf: Array(String(c).utf8))
            i += 1
        }
        return out
    }
}
