import Foundation
import SwiftUI

/// Datei-Format für gespeicherte Profile: Anzeige-Einstellungen plus Verbindung des aktuellen Tabs.
struct Profile: Codable {
    var prefs: PrefsData
    var tab: TabConfig
}

@MainActor
final class Workspace: ObservableObject {
    private static let key = "hardterm.tabs.v1"

    let prefs = Prefs()
    let library = Library()
    let appearance = Appearance()
    @Published var sessions: [Session] = []
    @Published var selectedId: UUID

    init() {
        var configs = [TabConfig]()
        if let raw = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([TabConfig].self, from: raw),
           !decoded.isEmpty {
            configs = decoded
        } else {
            configs = [TabConfig()]
        }
        let p = prefs
        let made = configs.map { Session(prefs: p, config: $0) }
        sessions = made
        selectedId = made[0].id
        for s in made { s.onConfigChange = { [weak self] in self?.saveTabs() } }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveTabs() }
        }
    }

    var current: Session {
        sessions.first { $0.id == selectedId } ?? sessions[0]
    }

    func addTab(_ kind: ConnKind) {
        let s = Session(prefs: prefs, config: TabConfig(kind: kind))
        s.onConfigChange = { [weak self] in self?.saveTabs() }
        sessions.append(s)
        selectedId = s.id
        saveTabs()
    }

    /// Öffnet eine gespeicherte Verbindung in einem neuen Tab.
    func openSaved(_ config: TabConfig, connect: Bool) {
        var c = config
        c.id = UUID()
        let s = Session(prefs: prefs, config: c)
        s.onConfigChange = { [weak self] in self?.saveTabs() }
        sessions.append(s)
        selectedId = s.id
        saveTabs()
        if connect { s.connect() }
    }

    /// Ersetzt die Verbindungsdaten eines Tabs durch eine gespeicherte Verbindung.
    func load(_ config: TabConfig, into session: Session) {
        session.disconnect()
        var c = config
        c.id = session.id
        session.config = c
    }

    func closeTab(_ id: UUID) {
        guard sessions.count > 1, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].disconnect()
        sessions.remove(at: idx)
        if selectedId == id { selectedId = sessions[min(idx, sessions.count - 1)].id }
        saveTabs()
    }

    func saveTabs() {
        if let raw = try? JSONEncoder().encode(sessions.map { $0.config }) {
            UserDefaults.standard.set(raw, forKey: Self.key)
        }
    }

    // MARK: Profile

    func exportProfile(of session: Session, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(Profile(prefs: prefs.data, tab: session.config)).write(to: url)
    }

    func importProfile(from url: URL, into session: Session) throws {
        let p = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
        var d = p.prefs
        d.scriptSource = prefs.data.scriptSource   // Skript und Historie bleiben unangetastet
        d.history = prefs.data.history
        session.disconnect()
        prefs.data = d
        var c = p.tab
        c.id = session.id
        session.config = c
    }
}
