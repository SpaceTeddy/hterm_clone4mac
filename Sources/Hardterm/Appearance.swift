import SwiftUI
import AppKit

/// Darstellung der Daten-/Terminalfenster: Schriftart, Farben, Transparenz.
/// Die Schriftgröße steht weiterhin in den Einstellungen der Ausgabe (⌘+ / ⌘−).
@MainActor
final class Appearance: ObservableObject {
    private static let key = "hardterm.appearance.v1"

    struct Values: Codable, Equatable {
        var fontFamily = ""               // leer = Systemschrift (monospaced)
        var textHex = "#D4D4D4"
        var backgroundHex = "#1E1E1E"
        var opacity = 1.0                 // 0.3 ... 1.0

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? ""
            textHex = try c.decodeIfPresent(String.self, forKey: .textHex) ?? "#D4D4D4"
            backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#1E1E1E"
            opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        }
    }

    @Published var data: Values {
        didSet {
            if let raw = try? JSONEncoder().encode(data) {
                UserDefaults.standard.set(raw, forKey: Self.key)
            }
        }
    }

    struct Preset: Identifiable {
        let name: String
        let text: String
        let background: String
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Dunkel", text: "#D4D4D4", background: "#1E1E1E"),
        Preset(name: "Hell", text: "#1F1F1F", background: "#FFFFFF"),
        Preset(name: "Grün auf Schwarz", text: "#33FF66", background: "#000000"),
        Preset(name: "Amber", text: "#FFB000", background: "#120C00"),
        Preset(name: "Solarized Dark", text: "#93A1A1", background: "#002B36"),
        Preset(name: "Dracula", text: "#F8F8F2", background: "#282A36"),
    ]

    init() {
        if let raw = UserDefaults.standard.data(forKey: Self.key),
           let v = try? JSONDecoder().decode(Values.self, from: raw) {
            data = v
        } else {
            data = Values()
        }
    }

    // MARK: Abgeleitete Werte

    var opacity: CGFloat { CGFloat(min(1, max(0.3, data.opacity))) }
    var textColor: NSColor { Self.nsColor(hex: data.textHex) }
    /// Deckende Hintergrundfarbe
    var backgroundBase: NSColor { Self.nsColor(hex: data.backgroundHex) }
    /// Hintergrundfarbe inklusive Transparenz
    var backgroundColor: NSColor { backgroundBase.withAlphaComponent(opacity) }

    /// Ändert sich, sobald sich etwas an der Darstellung ändert (für Neuaufbau der Ansichten).
    var signature: String {
        "\(data.fontFamily)|\(data.textHex)|\(data.backgroundHex)|\(Int(opacity * 100))"
    }

    func font(size: CGFloat, bold: Bool = false) -> NSFont {
        let fm = NSFontManager.shared
        if !data.fontFamily.isEmpty,
           var f = fm.font(withFamily: data.fontFamily, traits: [], weight: 5, size: size) {
            if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// Alle installierten Schriftfamilien mit fester Zeichenbreite.
    static func monospacedFamilies() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { fam in
            guard let f = fm.font(withFamily: fam, traits: [], weight: 5, size: 12) else { return false }
            return f.isFixedPitch
        }.sorted()
    }

    func apply(_ p: Preset) {
        data.textHex = p.text
        data.backgroundHex = p.background
    }

    func reset() {
        data = Values()
    }

    // MARK: Farbumwandlung

    static func nsColor(hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .gray }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func b(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }
}

// MARK: - Fenster-Transparenz

/// Setzt die Deckkraft des Fensters (die Steuerelemente bleiben lesbar, der Hintergrund scheint durch).
struct WindowConfigurator: NSViewRepresentable {
    var opacity: Double

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { Self.apply(v.window, opacity) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        let o = opacity
        DispatchQueue.main.async { Self.apply(v.window, o) }
    }

    private static func apply(_ w: NSWindow?, _ opacity: Double) {
        guard let w else { return }
        if opacity >= 0.995 {
            w.isOpaque = true
            w.backgroundColor = .windowBackgroundColor
        } else {
            // Das Fenster selbst ist durchsichtig; HoleBackground deckt alles außer den Terminalflächen ab.
            w.isOpaque = false
            w.backgroundColor = .clear
        }
        w.invalidateShadow()
    }
}

// MARK: - Transparenz nur in den Terminalflächen

struct PaneFrameKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

extension View {
    /// Meldet die Fläche dieser Ansicht, damit der Fensterhintergrund dort ausgespart wird.
    @ViewBuilder
    func transparentPane(active: Bool = true) -> some View {
        if active {
            background(GeometryReader { g in
                Color.clear.preference(key: PaneFrameKey.self,
                                       value: [g.frame(in: .named(HoleBackground.space))])
            })
        } else {
            self
        }
    }
}

/// Deckender Fensterhintergrund mit Aussparungen für die Terminalflächen.
struct HoleBackground: View {
    static let space = "hardterm.root"
    var frames: [CGRect]
    var transparent: Bool
    var paneColor: NSColor
    var opacity: CGFloat

    var body: some View {
        GeometryReader { g in
            let o = g.frame(in: .named(Self.space)).origin
            ZStack(alignment: .topLeading) {
                base(o)
                // Terminalflächen: Hintergrundfarbe mit der gewählten Deckkraft
                ForEach(frames.indices, id: \.self) { i in
                    Rectangle()
                        .fill(Color(nsColor: paneColor).opacity(transparent ? Double(opacity) : 1))
                        .frame(width: frames[i].width, height: frames[i].height)
                        .offset(x: frames[i].minX - o.x, y: frames[i].minY - o.y)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func base(_ o: CGPoint) -> some View {
        if transparent {
            Color(nsColor: .windowBackgroundColor)
                .mask {
                    Rectangle()
                        .overlay(alignment: .topLeading) {
                            ZStack(alignment: .topLeading) {
                                ForEach(frames.indices, id: \.self) { i in
                                    Rectangle()
                                        .frame(width: frames[i].width, height: frames[i].height)
                                        .offset(x: frames[i].minX - o.x, y: frames[i].minY - o.y)
                                        .blendMode(.destinationOut)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .compositingGroup()
                }
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

// MARK: - Einstellungen (⌘,)

struct AppearanceSettings: View {
    @EnvironmentObject var appearance: Appearance
    @EnvironmentObject var prefs: Prefs

    private let families = Appearance.monospacedFamilies()

    var body: some View {
        Form {
            Section("Schrift") {
                Picker("Schriftart", selection: $appearance.data.fontFamily) {
                    Text("System (Monospace)").tag("")
                    ForEach(families, id: \.self) { f in
                        Text(f).tag(f)
                    }
                }
                HStack {
                    Text("Größe")
                    Slider(value: $prefs.data.fontSize, in: 9...32, step: 1)
                    Text("\(Int(prefs.data.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }

            Section("Farben") {
                ColorPicker("Textfarbe", selection: colorBinding(\.textHex), supportsOpacity: false)
                ColorPicker("Hintergrund", selection: colorBinding(\.backgroundHex), supportsOpacity: false)
                Menu("Farbschema") {
                    ForEach(Appearance.presets) { p in
                        Button(LocalizedStringKey(p.name)) { appearance.apply(p) }
                    }
                }
            }

            Section("Transparenz") {
                HStack {
                    Text("Deckkraft")
                    Slider(value: $appearance.data.opacity, in: 0.3...1.0)
                    Text("\(Int((appearance.opacity * 100).rounded())) %")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
                Text("Gilt nur für die Terminal- und Textflächen; bei Werten unter 100 % scheint der Hintergrund durch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vorschau") {
                Text("user@host:~$ ls -la\ndrwxr-xr-x  5 user  staff  160 Nov  5 12:00 Hardterm\n0123456789 ÄÖÜ äöü ß {}[]()<>")
                    .font(Font(appearance.font(size: CGFloat(prefs.data.fontSize))))
                    .foregroundColor(Color(nsColor: appearance.textColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: appearance.backgroundBase))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Zurücksetzen") { appearance.reset() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<Appearance.Values, String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: Appearance.nsColor(hex: appearance.data[keyPath: keyPath])) },
            set: { appearance.data[keyPath: keyPath] = Appearance.hex(NSColor($0)) }
        )
    }
}
