import SwiftUI

@main
struct HardtermApp: App {
    @StateObject private var workspace = Workspace()

    init() {
        // Nötig, wenn die App per `swift run` ohne .app-Bundle gestartet wird
        NSApplication.shared.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        // Schreiben in eine geschlossene Pipe (SSH beendet) darf die App nicht beenden
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup("Hardterm") {
            ContentView()
                .environmentObject(workspace)
                .environmentObject(workspace.prefs)
                .environmentObject(workspace.library)
                .environmentObject(workspace.appearance)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neuer Seriell-Tab") { workspace.addTab(.serial) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Neuer Telnet-Tab") { workspace.addTab(.telnet) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Neuer SSH-Tab") { workspace.addTab(.ssh) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button("Verbindungen …") { workspace.library.showManager = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Makros bearbeiten …") { workspace.library.showMacros = true }
            }
            CommandGroup(after: .toolbar) {
                Button("Schrift größer") {
                    workspace.prefs.data.fontSize = min(28, workspace.prefs.data.fontSize + 1)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Schrift kleiner") {
                    workspace.prefs.data.fontSize = max(9, workspace.prefs.data.fontSize - 1)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }

        Settings {
            AppearanceSettings()
                .environmentObject(workspace.appearance)
                .environmentObject(workspace.prefs)
        }
    }
}
