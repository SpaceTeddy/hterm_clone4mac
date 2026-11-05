import Foundation
import SwiftUI

/// Ein Makro-Button: sendet Text (mit Escapes wie \r \n \xNN) oder Hex-Bytes.
struct Macro: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = L("Makro")
    var text = ""
    var hex = false
    var enter = true
}

/// Gespeicherte Telnet-/SSH-Verbindung (ohne Passwort).
struct SavedConnection: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var config: TabConfig

    var displayName: String {
        if !name.isEmpty { return name }
        if config.host.isEmpty { return L(config.kind.rawValue) }
        return config.user.isEmpty ? config.host : "\(config.user)@\(config.host)"
    }
}

/// Makros und Verbindungsliste; beides gilt für alle Tabs und wird in UserDefaults gespeichert.
@MainActor
final class Library: ObservableObject {
    private static let macroKey = "hardterm.macros.v1"
    private static let connKey = "hardterm.connections.v1"

    @Published var macros: [Macro] {
        didSet { Self.store(macros, key: Self.macroKey) }
    }
    @Published var connections: [SavedConnection] {
        didSet { Self.store(connections, key: Self.connKey) }
    }
    @Published var selectedConn: UUID?
    @Published var showManager = false
    @Published var showMacros = false

    init() {
        macros = Self.load([Macro].self, key: Self.macroKey) ?? []
        connections = Self.load([SavedConnection].self, key: Self.connKey) ?? []
        selectedConn = connections.first?.id
    }

    private static func store<T: Encodable>(_ value: T, key: String) {
        if let raw = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(raw, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let raw = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: raw)
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return connections.firstIndex { $0.id == id }
    }

    /// Speichert die Verbindung eines Tabs; gleiche Ziele werden aktualisiert statt doppelt angelegt.
    @discardableResult
    func save(_ config: TabConfig) -> SavedConnection {
        var c = config
        c.id = UUID()
        if let i = connections.firstIndex(where: {
            $0.config.kind == c.kind && $0.config.host == c.host
                && $0.config.port == c.port && $0.config.user == c.user
        }) {
            connections[i].config = c
            selectedConn = connections[i].id
            return connections[i]
        }
        let s = SavedConnection(name: "", config: c)
        connections.append(s)
        selectedConn = s.id
        return s
    }

    func addNew(_ kind: ConnKind) {
        let s = SavedConnection(name: L("Neue Verbindung (%@)", L(kind.rawValue)), config: TabConfig(kind: kind))
        connections.append(s)
        selectedConn = s.id
    }

    func deleteSelected() {
        guard let i = index(of: selectedConn) else { return }
        connections.remove(at: i)
        selectedConn = connections.indices.contains(i) ? connections[i].id : connections.last?.id
    }

    func addMacro() {
        macros.append(Macro(name: L("Makro %lld", macros.count + 1)))
    }
}

// MARK: - Makro-Leiste

struct MacroBar: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library

    var body: some View {
        HStack(spacing: 6) {
            Text("Makros")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(library.macros) { m in
                        Button(m.name) { session.sendMacro(m) }
                            .disabled(!session.isConnected)
                            .help(helpText(m))
                    }
                    if library.macros.isEmpty {
                        Text("Noch keine – mit „Bearbeiten“ anlegen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                library.showMacros = true
            } label: {
                Label("Bearbeiten", systemImage: "slider.horizontal.3")
            }
            .help("Makros anlegen und bearbeiten")
        }
        .controlSize(.small)
    }

    private func helpText(_ m: Macro) -> String {
        (m.hex ? "Hex: " : "") + m.text + (m.enter ? "  ⏎" : "")
    }
}

struct MacroEditor: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Makros").font(.headline)
            Text("Text darf Escapes enthalten (\\r \\n \\t \\xNN). „Hex“: Bytes wie 02 10 FF. „Enter“ hängt das Zeilenende an (seriell: Einstellung des Tabs, Telnet/SSH: Enter).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach($library.macros) { $m in
                        HStack(spacing: 8) {
                            TextField("Name", text: $m.name)
                                .frame(width: 130)
                            TextField("Text oder Hex", text: $m.text)
                                .font(.system(.body, design: .monospaced))
                            Toggle("Hex", isOn: $m.hex).toggleStyle(.checkbox)
                            Toggle("Enter", isOn: $m.enter).toggleStyle(.checkbox)
                            Button {
                                move(m.id, by: -1)
                            } label: { Image(systemName: "arrow.up") }
                            Button {
                                move(m.id, by: 1)
                            } label: { Image(systemName: "arrow.down") }
                            Button(role: .destructive) {
                                library.macros.removeAll { $0.id == m.id }
                            } label: { Image(systemName: "trash") }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 180)

            HStack {
                Button("Makro hinzufügen") { library.addMacro() }
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 720, height: 380)
    }

    private func move(_ id: UUID, by d: Int) {
        guard let i = library.macros.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard library.macros.indices.contains(j) else { return }
        library.macros.swapAt(i, j)
    }
}

// MARK: - Verbindungsmanager

struct ConnectionManager: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $library.selectedConn) {
                    ForEach(library.connections) { c in
                        Label(c.displayName, systemImage: c.config.kind.symbol)
                            .tag(c.id)
                    }
                }
                .frame(width: 230)

                Divider()

                Group {
                    if let i = library.index(of: library.selectedConn) {
                        detail(i)
                    } else {
                        VStack {
                            Spacer()
                            Text("Verbindung wählen oder neu anlegen")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Menu("Neu") {
                    Button("Telnet") { library.addNew(.telnet) }
                    Button("SSH") { library.addNew(.ssh) }
                }
                .fixedSize()
                Button("Aktuellen Tab speichern") {
                    let cfg = workspace.current.config
                    if cfg.kind != .serial { library.save(cfg) }
                }
                .disabled(workspace.current.kind == .serial)
                Button("Löschen") { library.deleteSelected() }
                    .disabled(library.selectedConn == nil)
                Spacer()
                Button("Im aktuellen Tab laden") {
                    if let i = library.index(of: library.selectedConn) {
                        workspace.load(library.connections[i].config, into: workspace.current)
                        dismiss()
                    }
                }
                .disabled(library.selectedConn == nil || workspace.current.kind == .serial)
                Button("Verbinden (neuer Tab)") {
                    if let i = library.index(of: library.selectedConn) {
                        workspace.openSaved(library.connections[i].config, connect: true)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(library.selectedConn == nil)
                Button("Schließen") { dismiss() }
            }
            .padding(10)
        }
        .frame(width: 780, height: 420)
    }

    @ViewBuilder
    private func detail(_ i: Int) -> some View {
        Form {
            TextField("Name", text: $library.connections[i].name)
            Picker("Art", selection: $library.connections[i].config.kind) {
                Text("Telnet").tag(ConnKind.telnet)
                Text("SSH").tag(ConnKind.ssh)
            }
            .onChange(of: library.connections[i].config.kind) {
                library.connections[i].config.port = library.connections[i].config.kind.defaultPort
            }
            TextField("Host", text: $library.connections[i].config.host)
            TextField("Port", value: $library.connections[i].config.port, format: .number.grouping(.never))
            if library.connections[i].config.kind == .ssh {
                TextField("Benutzer", text: $library.connections[i].config.user)
                TextField("Schlüsseldatei", text: $library.connections[i].config.keyFile)
                TextField("Optionen", text: $library.connections[i].config.extraArgs)
                Text("Passwörter werden nie gespeichert – Schlüssel-Login empfohlen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
