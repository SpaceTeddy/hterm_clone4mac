import SwiftUI
import UniformTypeIdentifiers

/// Bewusst ObservableObject statt @State: @State ist in neueren SDKs ein Macro und
/// braucht das SwiftUIMacros-Plugin, das in den Command Line Tools fehlen kann.
@MainActor
final class InputState: ObservableObject {
    @Published var text = ""
}

private let mono = Font.system(.body, design: .monospaced)

// MARK: - Fenster mit Tabs

struct ContentView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var library: Library
    @EnvironmentObject var appearance: Appearance

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Divider()
            // Alle Tabs bleiben lebendig (Verbindungen, Eingaben, Skripte); nur der gewählte ist sichtbar.
            ZStack {
                ForEach(workspace.sessions) { s in
                    let selected = s.id == workspace.selectedId
                    SessionView()
                        .environmentObject(s)
                        .opacity(selected ? 1 : 0)
                        .disabled(!selected)
                        .zIndex(selected ? 1 : 0)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .coordinateSpace(name: HoleBackground.space)
        .background(WindowConfigurator(opacity: appearance.data.opacity))
        .backgroundPreferenceValue(PaneFrameKey.self) { frames in
            HoleBackground(frames: frames,
                           transparent: appearance.data.opacity < 0.995,
                           paneColor: appearance.backgroundBase,
                           opacity: appearance.opacity)
        }
        .sheet(isPresented: $library.showManager) {
            ConnectionManager()
        }
        .sheet(isPresented: $library.showMacros) {
            MacroEditor()
        }
        .searchable(text: filterBinding, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItemGroup {
                SessionToolbar(session: workspace.current)
            }
        }
    }

    private var filterBinding: Binding<String> {
        Binding(get: { workspace.current.filter },
                set: { workspace.current.filter = $0 })
    }
}

struct TabBar: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var library: Library

    var body: some View {
        HStack(spacing: 4) {
            ForEach(workspace.sessions) { s in
                TabItem(session: s)
            }
            Menu {
                Button("Seriell") { workspace.addTab(.serial) }
                Button("Telnet") { workspace.addTab(.telnet) }
                Button("SSH") { workspace.addTab(.ssh) }
                if !library.connections.isEmpty {
                    Divider()
                    ForEach(library.connections) { c in
                        Button {
                            workspace.openSaved(c.config, connect: true)
                        } label: {
                            Label(c.displayName, systemImage: c.config.kind.symbol)
                        }
                    }
                }
                Divider()
                Button("Verbindungen verwalten …") { library.showManager = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Neuer Tab (⌘T seriell, ⇧⌘T Telnet, ⌥⌘T SSH)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct TabItem: View {
    @ObservedObject var session: Session
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        let selected = workspace.selectedId == session.id
        HStack(spacing: 6) {
            Circle()
                .fill(session.isConnected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Image(systemName: session.kind.symbol)
                .foregroundStyle(.secondary)
            Text(session.title)
                .lineLimit(1)
            if workspace.sessions.count > 1 {
                Button {
                    workspace.closeTab(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Tab schließen")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectedId = session.id }
    }
}

struct SessionToolbar: View {
    @ObservedObject var session: Session
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var library: Library

    var body: some View {
        Button { library.showManager = true } label: {
            Label("Verbindungen", systemImage: "list.bullet.rectangle")
        }
        .help("Verbindungsmanager (⇧⌘O)")
        Button { Panels.copy(session.exportRx()) } label: {
            Label("Kopieren", systemImage: "doc.on.doc")
        }
        .help("Gesamten Empfangsverlauf kopieren")
        Menu {
            Button("Profil laden …") {
                if let u = Panels.open(types: [.json]) {
                    do { try workspace.importProfile(from: u, into: session) }
                    catch { session.info(L("Profil ungültig: %@", error.localizedDescription)) }
                }
            }
            Button("Profil speichern …") {
                if let u = Panels.save(name: "profil.json") {
                    do { try workspace.exportProfile(of: session, to: u) }
                    catch { session.info(L("Speichern fehlgeschlagen: %@", error.localizedDescription)) }
                }
            }
            Button("Darstellung …") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Divider()
            if session.logURL == nil {
                Button("Mitschnitt starten …") {
                    if let u = Panels.save(name: "mitschnitt.bin") { session.startLog(u) }
                }
            } else {
                Button("Mitschnitt beenden") { session.stopLog() }
            }
            if session.kind == .serial {
                Button("Break senden") { session.sendBreak() }
                    .disabled(!session.isConnected)
                Toggle("Automatisch neu verbinden", isOn: $prefs.data.autoReconnect)
            }
        } label: {
            Label("Mehr", systemImage: "ellipsis.circle")
        }
        Toggle(isOn: $session.showScript) {
            Label("Skript", systemImage: "curlybraces")
        }
        .help("Skript-Panel ein-/ausblenden")
    }
}

// MARK: - Inhalt eines Tabs (Aufteilung wie bei HTerm)

struct SessionView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var appearance: Appearance

    var body: some View {
        if session.kind == .serial {
            serialBody
        } else {
            terminalBody
        }
    }

    /// Telnet/SSH: reine Konsole, Tastatur geht direkt an die Verbindung.
    private var terminalBody: some View {
        VStack(spacing: 6) {
            ConnectionBar()
                .controlSize(.small)
            MacroBar()
            VSplitView {
                TerminalPane(session: session,
                             appearance: appearance,
                             active: workspace.selectedId == session.id,
                             fontSize: prefs.data.fontSize)
                    .transparentPane(active: workspace.selectedId == session.id)
                    .frame(minHeight: 200)
                if session.showScript {
                    ScriptPanel()
                        .frame(minHeight: 170, idealHeight: 240)
                }
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(session.isConnected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(session.statusText)
                Spacer(minLength: 0)
                Text("Rx \(session.rxCount)  Tx \(session.txCount)")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private var serialBody: some View {
        VStack(spacing: 6) {
            VStack(spacing: 6) {
                ConnectionBar()
                GeneralOptions()
                OutputOptions()
            }
            .controlSize(.small)

            VSplitView {
                GroupBox("Empfangene Daten") {
                    RxPane(filter: session.filter)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 150)

                VStack(spacing: 6) {
                    MacroBar()
                    VStack(spacing: 6) {
                        InputOptions()
                        InputGroup()
                    }
                    .controlSize(.small)
                    GroupBox("Gesendete Daten") {
                        TxPane()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: 80)
                }
                .frame(minHeight: 260)

                if session.showScript {
                    ScriptPanel()
                        .frame(minHeight: 170, idealHeight: 240)
                }
            }

            StatusBar()
        }
        .padding(8)
    }
}

// MARK: - Verbindungsleiste (je nach Art des Tabs)

struct ConnectionBar: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var library: Library

    private let baudPresets = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200,
                               230400, 460800, 921600, 1_000_000, 2_000_000, 3_000_000]

    var body: some View {
        HStack(spacing: 10) {
            Button {
                session.toggleConnection()
            } label: {
                Text(buttonTitle)
                    .frame(width: 80)
            }
            .buttonStyle(.borderedProminent)
            .tint(session.isConnected || session.isConnecting ? .red : .green)

            Group {
                switch session.kind {
                case .serial: serialFields
                case .telnet: telnetFields
                case .ssh: sshFields
                }
            }
            .disabled(session.isConnected || session.isConnecting)

            if session.kind == .serial {
                Toggle("Meldungen", isOn: $prefs.data.showMessages)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("Status- und Fehlermeldungen im Empfangsfenster anzeigen")
            }
            if session.kind != .serial {
                Button {
                    library.save(session.config)
                } label: {
                    Label("Speichern", systemImage: "star")
                }
                .help("Verbindung im Verbindungsmanager speichern (ohne Passwort)")
            }
            if session.kind == .telnet {
                Toggle("Lokales Echo", isOn: $session.localEcho)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("Eigene Eingabe lokal anzeigen, falls der Server nicht selbst zurückschreibt")
            }
            Spacer(minLength: 0)
        }
    }

    private var buttonTitle: String {
        if session.isConnecting { return L("Abbrechen") }
        return session.isConnected ? L("Trennen") : L("Verbinden")
    }

    @ViewBuilder
    private var serialFields: some View {
        Text("Port")
        Picker("", selection: $session.config.serial.path) {
            Text("–").tag("")
            ForEach(session.ports, id: \.self) { p in
                Text(session.shortName(p)).tag(p)
            }
        }
        .labelsHidden()
        .frame(width: 200)
        Button("R") { session.refreshPorts() }
            .help("Portliste neu einlesen")

        Text("Baud")
        TextField("", value: $session.config.serial.baud, format: .number.grouping(.never))
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
        Menu {
            ForEach(baudPresets, id: \.self) { b in
                Button("\(b)") { session.config.serial.baud = b }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()

        Text("Data")
        Picker("", selection: $session.config.serial.dataBits) {
            ForEach([5, 6, 7, 8], id: \.self) { Text("\($0)").tag($0) }
        }
        .labelsHidden()
        .frame(width: 55)

        Text("Stop")
        Picker("", selection: $session.config.serial.stopBits) {
            ForEach([1, 2], id: \.self) { Text("\($0)").tag($0) }
        }
        .labelsHidden()
        .frame(width: 55)

        Text("Parity")
        Picker("", selection: $session.config.serial.parity) {
            ForEach(Parity.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }
        .labelsHidden()
        .frame(width: 100)

        Text("Flow")
        Picker("", selection: $session.config.serial.flow) {
            ForEach(FlowControl.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }
        .labelsHidden()
        .frame(width: 105)
    }

    @ViewBuilder
    private var telnetFields: some View {
        Text("Host")
        TextField("Hostname oder IP", text: $session.config.host)
            .frame(width: 260)
            .onSubmit { session.connect() }
        Text("Port")
        TextField("", value: $session.config.port, format: .number.grouping(.never))
            .frame(width: 60)
            .multilineTextAlignment(.trailing)
            .onSubmit { session.connect() }
    }

    @ViewBuilder
    private var sshFields: some View {
        Text("Host")
        TextField("Hostname oder IP", text: $session.config.host)
            .frame(width: 190)
            .onSubmit { session.connect() }
        Text("Port")
        TextField("", value: $session.config.port, format: .number.grouping(.never))
            .frame(width: 50)
            .multilineTextAlignment(.trailing)
        Text("Benutzer")
        TextField("", text: $session.config.user)
            .frame(width: 110)
            .onSubmit { session.connect() }
        Text("Schlüssel")
        TextField("optional, z. B. ~/.ssh/id_ed25519", text: $session.config.keyFile)
            .frame(width: 190)
        Button("…") {
            if let u = Panels.open() { session.config.keyFile = u.path }
        }
        .help("Schlüsseldatei wählen")
        Text("Optionen")
        TextField("z. B. -J jump -o ServerAliveInterval=30", text: $session.config.extraArgs)
            .frame(width: 190)
            .help("Zusätzliche ssh-Argumente, durch Leerzeichen getrennt")
    }
}

// MARK: - Allgemein

struct CounterBox: View {
    let value: Int
    var width: CGFloat = 70

    var body: some View {
        Text("\(value)")
            .monospacedDigit()
            .frame(width: width, alignment: .trailing)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
    }
}

struct GeneralOptions: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        GroupBox("Allgemein") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Rx")
                    CounterBox(value: session.rxCount)
                    Button("Reset") { session.resetRxCount() }

                    Text("Tx")
                    CounterBox(value: session.txCount)
                    Button("Reset") { session.resetTxCount() }

                    Text("Zähle Byte")
                    TextField("", value: $prefs.data.countByte, format: .number)
                        .frame(width: 42)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $prefs.data.countByte, in: 0...255)
                        .labelsHidden()
                    CounterBox(value: session.byteHits, width: 50)
                    Button("Reset") { session.resetByteHits() }

                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Text("Zeilenumbruch bei")
                    Picker("", selection: $prefs.data.rxLineMode) {
                        ForEach(RxLineMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    if prefs.data.rxLineMode == .idle {
                        Stepper("Pause \(prefs.data.idleGapMs) ms",
                                value: $prefs.data.idleGapMs, in: 5...2000, step: 5)
                    }
                    Stepper(prefs.data.wrapBytes == 0 ? L("Umbruch alle: aus") : L("Umbruch alle %lld Bytes", prefs.data.wrapBytes),
                            value: $prefs.data.wrapBytes, in: 0...4096, step: 8)
                    Toggle("CR/LF-Zeichen anzeigen", isOn: $prefs.data.showControl)
                        .toggleStyle(.checkbox)
                    Toggle("Zeitstempel", isOn: $prefs.data.showTimestamps)
                        .toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Ausgabe-Optionen

struct LEDView: View {
    let name: String
    let on: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(name).font(.caption2)
            Circle()
                .fill(on ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 11, height: 11)
        }
    }
}

struct OutputOptions: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        GroupBox("Ausgabe-Optionen") {
            HStack(spacing: 12) {
                Button("Ausgabe leeren") { session.clearRx() }

                Toggle("Ascii", isOn: $prefs.data.outAscii).toggleStyle(.checkbox)
                Toggle("Hex", isOn: $prefs.data.outHex).toggleStyle(.checkbox)
                Toggle("Dez", isOn: $prefs.data.outDec).toggleStyle(.checkbox)
                Toggle("Bin", isOn: $prefs.data.outBin).toggleStyle(.checkbox)

                Button("Ausgabe speichern") {
                    if let u = Panels.save(name: "ausgabe.txt") {
                        try? session.exportRx().write(to: u, atomically: true, encoding: .utf8)
                    }
                }

                Toggle("Leeren ab (Bytes)", isOn: $prefs.data.clearAtEnabled).toggleStyle(.checkbox)
                TextField("", value: $prefs.data.clearAtBytes, format: .number.grouping(.never))
                    .frame(width: 65)
                    .multilineTextAlignment(.trailing)
                    .disabled(!prefs.data.clearAtEnabled)

                Toggle("Autoscroll", isOn: $prefs.data.autoScroll).toggleStyle(.checkbox)

                Picker("", selection: $prefs.data.cellView) {
                    Text("Text").tag(false)
                    Text("Zellen").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .help("Text: gut lesbare Zeilen. Zellen: Byte-Ansicht wie bei HTerm.")

                HStack(spacing: 2) {
                    Text("Aa").foregroundStyle(.secondary)
                    Stepper("", value: $prefs.data.fontSize, in: 9...28, step: 1)
                        .labelsHidden()
                }
                .help("Schriftgröße der Textansicht (⌘+ / ⌘−)")

                Spacer(minLength: 0)

                if session.kind == .serial {
                    HStack(spacing: 10) {
                        LEDView(name: "CTS", on: session.modem.cts)
                        LEDView(name: "DSR", on: session.modem.dsr)
                        LEDView(name: "RI", on: session.modem.ri)
                        LEDView(name: "DCD", on: session.modem.dcd)
                    }
                }
            }
            .padding(4)
        }
    }
}

// MARK: - Empfangs- und Sendefenster

struct RxPane: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs
    let filter: String

    var body: some View {
        DataPane(lines: visible(),
                 formats: prefs.data.outFormats,
                 signature: "\(filter)|\(prefs.data.showMessages)")
    }

    private func visible() -> [Line] {
        var l = session.rxLines
        if !prefs.data.showMessages { l = l.filter { $0.dir != .info } }
        if !filter.isEmpty {
            l = l.filter { session.searchText($0).localizedCaseInsensitiveContains(filter) }
        }
        return l
    }
}

struct TxPane: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        DataPane(lines: session.txLines, formats: prefs.data.inFormats)
    }
}

// MARK: - Eingabe-Optionen

struct InputOptions: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        GroupBox("Eingabe-Optionen") {
            HStack(spacing: 12) {
                Button("Gesendetes leeren") { session.clearTx() }

                Toggle("Ascii", isOn: $prefs.data.inAscii).toggleStyle(.checkbox)
                Toggle("Hex", isOn: $prefs.data.inHex).toggleStyle(.checkbox)
                Toggle("Dez", isOn: $prefs.data.inDec).toggleStyle(.checkbox)
                Toggle("Bin", isOn: $prefs.data.inBin).toggleStyle(.checkbox)

                Text("Bei Enter anhängen")
                Picker("", selection: $prefs.data.lineEnding) {
                    ForEach(LineEnding.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)

                Button("Datei senden …") {
                    if let u = Panels.open() { session.sendFile(u) }
                }
                .disabled(!session.isConnected)

                Toggle("DTR", isOn: $session.dtr).toggleStyle(.button)
                Toggle("RTS", isOn: $session.rts).toggleStyle(.button)

                Spacer(minLength: 0)
            }
            .padding(4)
        }
    }
}

// MARK: - Eingabe mit Historie

struct InputGroup: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs
    @StateObject private var input = InputState()
    @FocusState private var focused: Bool

    private var secretMode: Bool { session.awaitingSecret && session.kind != .serial }

    var body: some View {
        GroupBox("Eingabe") {
            HStack(spacing: 8) {
                Text("Typ")
                Picker("", selection: $prefs.data.inputFormat) {
                    ForEach(InputFormat.allCases) { f in
                        Text(shortName(f)).tag(f)
                    }
                }
                .labelsHidden()
                .frame(width: 80)

                if secretMode {
                    SecureField("Passwort (wird nicht angezeigt oder gespeichert)", text: $input.text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(send)
                } else {
                    TextField(placeholder, text: $input.text)
                        .textFieldStyle(.roundedBorder)
                        .font(mono)
                        .focused($focused)
                        .onSubmit(send)
                        .onKeyPress(.upArrow) {
                            if let t = session.navigateHistory(-1) { input.text = t }
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            if let t = session.navigateHistory(1) { input.text = t }
                            return .handled
                        }
                }

                Menu {
                    if prefs.data.history.isEmpty {
                        Text("Noch keine Einträge")
                    } else {
                        ForEach(Array(prefs.data.history.reversed().enumerated()), id: \.offset) { _, h in
                            Button(h) {
                                input.text = h
                                session.historyIndex = nil
                            }
                        }
                        Divider()
                        Button("Historie löschen") { session.clearHistory() }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Befehls-Historie (auch mit Pfeil hoch/runter im Feld)")

                Button("Senden", action: send)
                    .disabled(!session.isConnected)
            }
            .padding(4)
        }
        .onChange(of: session.awaitingSecret) {
            focused = true
        }
    }

    private func shortName(_ f: InputFormat) -> String {
        switch f {
        case .ascii: return "ASC"
        case .hex: return "HEX"
        case .dec: return "DEC"
        case .bin: return "BIN"
        }
    }

    private var placeholder: String {
        if session.kind != .serial { return L("Befehl eingeben und Enter drücken") }
        switch prefs.data.inputFormat {
        case .ascii: return L("Text (Escapes: \\n \\r \\t \\xNN)")
        case .hex: return L("Hex, z. B. 02 10 FF")
        case .dec: return L("Dezimal, z. B. 2 16 255")
        case .bin: return L("Binär, z. B. 00000010 00010000")
        }
    }

    private func send() {
        if session.sendInput(input.text) {
            input.text = ""
        }
    }
}

// MARK: - Statusleiste

struct StatusBar: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        HStack(spacing: 0) {
            Text("Historie \(position)/\(prefs.data.history.count)")
                .padding(.horizontal, 8)
                .frame(width: 140, alignment: .leading)
            Divider().frame(height: 14)
            Circle()
                .fill(session.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
                .padding(.leading, 8)
            Text(session.statusText)
                .padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var position: String {
        if let i = session.historyIndex { return String(i + 1) }
        return "-"
    }
}

// MARK: - Skript-Panel

struct ScriptPanel: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if session.scriptRunning { session.stopScript() } else { session.runScript() }
                } label: {
                    Label(session.scriptRunning ? L("Stopp") : L("Ausführen"),
                          systemImage: session.scriptRunning ? "stop.fill" : "play.fill")
                }
                .tint(session.scriptRunning ? .red : .green)
                .buttonStyle(.borderedProminent)

                Button("Öffnen …") {
                    if let u = Panels.open(types: [.javaScript, .plainText]),
                       let s = try? String(contentsOf: u, encoding: .utf8) {
                        prefs.data.scriptSource = s
                    }
                }
                Button("Speichern …") {
                    if let u = Panels.save(name: "skript.js") {
                        try? prefs.data.scriptSource.write(to: u, atomically: true, encoding: .utf8)
                    }
                }
                Menu("Beispiele") {
                    Button("Einfach: Senden & Antwort") { prefs.data.scriptSource = ScriptSamples.basic }
                    Button("Schleife mit Timeout") { prefs.data.scriptSource = ScriptSamples.loop }
                    Button("Hex-Telegramm") { prefs.data.scriptSource = ScriptSamples.hex }
                }
                .fixedSize()
                Spacer()
                Text("send · sendHex · sendBytes · waitFor · sleep · flush · received · log · clear · connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            Divider()
            TextEditor(text: $prefs.data.scriptSource)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
        }
    }
}
