# Hardterm

Natives serielles Terminal für macOS (Apple Silicon), SwiftUI + POSIX-termios, ohne Abhängigkeiten.

## Bauen & Starten

Voraussetzung: Xcode oder Command Line Tools (Swift 5.9+), macOS 14+.

    chmod +x build_app.sh
    ./build_app.sh
    open build/Hardterm.app

Zum schnellen Testen geht auch `swift run`.
Wird die App auf einen anderen Mac kopiert: `xattr -cr Hardterm.app`.

## Tabs: Seriell, Telnet, SSH

Mit „+“ in der Tab-Leiste (⌘T seriell, ⇧⌘T Telnet, ⌥⌘T SSH) öffnest du weitere Tabs. Jeder Tab hat eigene Verbindung, Ein-/Ausgabe, Zähler und Skript-Lauf; die Tabs werden beim Neustart wiederhergestellt (ohne automatisch zu verbinden).

Telnet- und SSH-Tabs sind eine **echte Terminal-Konsole** (kein Eingabefeld): Tastendrücke gehen direkt an die Verbindung, Passwortabfragen erscheinen direkt im Terminal, Scrollback per Mausrad oder ⇧Bild↑/↓, Markieren mit der Maus, ⌘C/⌘V. Eingebaut ist ein xterm-kompatibler Emulator (Farben inkl. 256/TrueColor, Cursor, Scrollbereiche, Alternate Screen), daher laufen auch vim, top, less, htop und Tab-Vervollständigung. Die Fenstergröße wird an die Gegenseite gemeldet.

- **Telnet**: Host und Port (Standard 23); verhandelt ECHO, SGA, Terminal-Typ (xterm-256color) und Fenstergröße (NAWS). Enter sendet CR LF. „Lokales Echo“ für Server, die nicht selbst zurückschreiben (Roh-TCP-Konsolen).
- **SSH**: nutzt das System-`ssh` in einem eigenen Pseudo-Terminal (dafür wird `/usr/bin/perl` benutzt; ohne Perl Ersatz über `script` mit fester Größe). Felder: Host, Port, Benutzer, Schlüsseldatei, zusätzliche Optionen (z. B. `-J jump`).
- Grenzen: keine Maus-Weitergabe an Programme, keine Sixel/Grafik, Breitzeichen (CJK/Emoji) werden einspaltig dargestellt.
- Die Optionen/Eingabefelder (Hex-Ansicht, Historie usw.) gibt es nur im seriellen Tab.

## Makros und Verbindungsmanager

- **Makro-Leiste** in jedem Tab: ein Klick sendet Text (Escapes `\r \n \t \xNN`) oder Hex-Bytes, optional mit Zeilenende. Anlegen/Sortieren über „Bearbeiten“ in der Leiste oder Menü Ablage → „Makros bearbeiten …“. Makros gelten für alle Tabs.
- **Verbindungsmanager** (⇧⌘O oder Werkzeugleiste „Verbindungen“): Telnet-/SSH-Ziele speichern, bearbeiten, löschen; „Verbinden“ öffnet einen neuen Tab, „Im aktuellen Tab laden“ ersetzt die Daten des aktuellen Tabs. Der Stern in der Verbindungsleiste speichert den aktuellen Tab. Das „+“ in der Tab-Leiste listet gespeicherte Verbindungen zum direkten Öffnen. Passwörter werden nie gespeichert.

## Darstellung

Einstellungen (⌘, oder Werkzeugleiste → Mehr → „Darstellung …“): Schriftart (alle installierten Monospace-Schriften), Größe, Textfarbe, Hintergrundfarbe, fertige Farbschemata (Dunkel, Hell, Grün auf Schwarz, Amber, Solarized Dark, Dracula) und Deckkraft der Terminal- und Textflächen (30–100 %, darunter scheint der Desktop durch; Bedienelemente bleiben deckend). Gilt für die Terminalansicht (Telnet/SSH) und die Textansicht (seriell); die Zellenansicht behält ihre Farben.

## Sprachen

Die Oberfläche folgt der Spracheinstellung des Macs (Systemeinstellungen → Allgemein → Sprache & Region): **Deutsch, Englisch, Französisch, Spanisch, Italienisch**; alle anderen Sprachen zeigen Englisch. Die Übersetzungen liegen in `Resources/<sprache>.lproj/Localizable.strings` (Schlüssel = deutscher Originaltext) und werden von `build_app.sh` ins App-Bundle kopiert. Eine neue Sprache: Ordner `xx.lproj` mit übersetzter `Localizable.strings` anlegen und `xx` in `CFBundleLocalizations` (Info.plist) eintragen. Zum Testen einer anderen Sprache ohne Systemumstellung: `open build/Hardterm.app --args -AppleLanguages "(fr)"`.
Bei `swift run` (ohne App-Bundle) bleibt die Oberfläche deutsch.

## Funktionen

- Ports `/dev/cu.*` mit automatischer Aktualisierung, Hot-Unplug-Erkennung, optional automatisches Neuverbinden (z. B. bei ESP32-Reset)
- Baudrate frei wählbar (auch nicht-standard), 5–8 Datenbits, 1–2 Stopbits, Parität, RTS/CTS bzw. XON/XOFF
- DTR/RTS schalten, CTS/DSR/DCD/RI-Anzeige, Break senden
- Aufbau wie HTerm: Verbindungsleiste, Allgemein (Zähler), Ausgabe-Optionen, Empfangene Daten, Eingabe-Optionen, Eingabe, Gesendete Daten, Statusleiste
- Zwei Ansichten (Umschalter in den Ausgabe-Optionen): „Text“ (Standard) mit gut lesbaren, markier- und kopierbaren Zeilen, ⌘F-Suche, ANSI-Farben und einstellbarer Schriftgröße (⌘+ / ⌘−); „Zellen“ wie bei HTerm
- Empfangene und gesendete Bytes als farbige Zellen (ASCII, Hex, Dez, Bin einzeln zuschaltbar); Rechtsklick auf eine Zeile: kopieren als ASCII/Hex/Dezimal/Binär
- Zähler für Rx/Tx und für ein frei wählbares Byte (z. B. 13), automatisches Leeren ab N Bytes, Filter, Zeitstempel (ms)
- Zeilenumbruch bei LF, CR, CR+LF, Zeitlücke oder nach N Bytes
- Senden in ASCII (Escapes `\n \r \t \0 \\ \xNN`), Hex, Dez, Bin; Zeilenende beim Enter wählbar
- Befehls-Historie: Pfeil hoch/runter im Eingabefeld, Verlaufsmenü (Uhr-Symbol) neben dem Feld, Anzeige „Historie n/Anzahl“ in der Statusleiste, bleibt über Neustarts erhalten (letzte 50)
- Datei senden, Rohdaten-Mitschnitt in Datei, Verlauf kopieren/exportieren
- Profile als JSON speichern/laden, Einstellungen werden automatisch gemerkt

## Skripte (JavaScript)

Über die Werkzeugleiste „Skript“. Skripte laufen auf eigenem Thread, `sleep` und `waitFor` blockieren normal.

| Funktion | Bedeutung |
|---|---|
| `send(text)` | Text senden (JS-Escapes wie `"\r\n"` funktionieren) |
| `sendHex("AA BB")` | Bytes aus Hex senden |
| `sendBytes([1,2,3])` | Bytes aus Array senden |
| `waitFor(text, timeoutMs)` | wartet auf Text; gibt empfangenen Text bis inkl. Treffer zurück oder `null` |
| `sleep(ms)` | Pause |
| `flush()` / `received()` | Skript-Empfangspuffer leeren / komplett entnehmen |
| `log(x)`, `clear()`, `connected()` | Ausgabe im Terminal, Terminal leeren, Verbindungsstatus |

Beispiel:

    flush();
    send("AT\r\n");
    if (waitFor("OK", 2000) === null) log("Timeout");

## Aufbau

- `SerialPort.swift` termios, Lesen/Schreiben, Steuerleitungen
- `Session.swift` Zustand, Zeilenpuffer, Senden, Mitschnitt, Skriptstart
- `ScriptRunner.swift` JavaScriptCore-Anbindung
- `Formatting.swift` Darstellung und Eingabe-Parser
- `ContentView.swift` UI
