# Hardterm

Native serial terminal for macOS (Apple Silicon), SwiftUI + POSIX termios, no dependencies.

## Build & Run

Requirements: Xcode or Command Line Tools (Swift 5.9+), macOS 14+.

    chmod +x build_app.sh
    ./build_app.sh
    open build/Hardterm.app

For quick testing, `swift run` works too.
If you copy the app to another Mac: `xattr -cr Hardterm.app`.

## Versioning & Releases

The version number lives in the `VERSION` file (semantic versioning, e.g. `0.1.0`). `build_app.sh` writes it into the app's `Info.plist`; the build number is the git commit count.

A GitHub Actions workflow (`.github/workflows/build.yml`) builds the app on every push to `main` and every pull request, and attaches the zipped app as a workflow artifact.

To publish a release:

    echo "0.2.0" > VERSION
    git commit -am "Release 0.2.0"
    git tag v0.2.0
    git push && git push --tags

The tag must match `VERSION`; the workflow then creates a GitHub release with `Hardterm-0.2.0-macOS-arm64.zip` and auto-generated release notes. The app is ad-hoc signed only (not notarized), so users need to run `xattr -cr Hardterm.app` after downloading.

## Tabs: Serial, Telnet, SSH

Use "+" in the tab bar (⌘T serial, ⇧⌘T Telnet, ⌥⌘T SSH) to open additional tabs. Each tab has its own connection, input/output, counters and script run; tabs are restored on relaunch (without connecting automatically).

Telnet and SSH tabs are a **real terminal console** (no input field): keystrokes go straight to the connection, password prompts appear directly in the terminal, scrollback via mouse wheel or ⇧PageUp/PageDown, selection with the mouse, ⌘C/⌘V. A built-in xterm-compatible emulator (colors incl. 256/TrueColor, cursor, scroll regions, alternate screen) means vim, top, less, htop and tab completion work as well. The window size is reported to the remote side.

- **Telnet**: host and port (default 23); negotiates ECHO, SGA, terminal type (xterm-256color) and window size (NAWS). Enter sends CR LF. "Local echo" for servers that don't echo back themselves (raw TCP consoles).
- **SSH**: uses the system `ssh` in its own pseudo-terminal (via `/usr/bin/perl`; without Perl, falls back to `script` with a fixed size). Fields: host, port, user, key file, additional options (e.g. `-J jump`).
- Limitations: no mouse passthrough to programs, no Sixel/graphics, wide characters (CJK/emoji) are rendered single-width.
- The options/input fields (hex view, history, etc.) are only available in the serial tab.

## Macros and Connection Manager

- **Macro bar** in every tab: one click sends text (escapes `\r \n \t \xNN`) or hex bytes, optionally with a line ending. Create/reorder via "Edit" in the bar or File menu → "Edit Macros …". Macros apply to all tabs.
- **Connection manager** (⇧⌘O or toolbar "Connections"): save, edit and delete Telnet/SSH targets; "Connect" opens a new tab, "Load into current tab" replaces the current tab's settings. The star in the connection bar saves the current tab. The "+" in the tab bar lists saved connections for opening directly. Passwords are never stored.

## Appearance

Settings (⌘, or toolbar → More → "Appearance …"): font (all installed monospace fonts), size, text color, background color, preset color schemes (Dark, Light, Green on Black, Amber, Solarized Dark, Dracula) and opacity of the terminal and text areas (30–100 %, the desktop shows through below that; controls stay opaque). Applies to the terminal view (Telnet/SSH) and the text view (serial); the cell view keeps its colors.

## Languages

The UI follows the Mac's language setting (System Settings → General → Language & Region): **German, English, French, Spanish, Italian**; all other languages show English. Translations live in `Resources/<language>.lproj/Localizable.strings` (key = original German text) and are copied into the app bundle by `build_app.sh`. To add a language: create a folder `xx.lproj` with a translated `Localizable.strings` and add `xx` to `CFBundleLocalizations` (Info.plist). To test another language without changing the system setting: `open build/Hardterm.app --args -AppleLanguages "(fr)"`.
With `swift run` (no app bundle), the UI stays in German.

## Features

- Ports `/dev/cu.*` with automatic refresh, hot-unplug detection, optional automatic reconnect (e.g. on ESP32 reset)
- Freely selectable baud rate (including non-standard), 5–8 data bits, 1–2 stop bits, parity, RTS/CTS or XON/XOFF
- Toggle DTR/RTS, CTS/DSR/DCD/RI indicators, send break
- Layout like HTerm: connection bar, general (counters), output options, received data, input options, input, sent data, status bar
- Two views (switch in the output options): "Text" (default) with readable, selectable and copyable lines, ⌘F search, ANSI colors and adjustable font size (⌘+ / ⌘−); "Cells" like HTerm
- Received and sent bytes as colored cells (ASCII, hex, dec, bin individually toggleable); right-click a line: copy as ASCII/hex/decimal/binary
- Counters for Rx/Tx and for a freely selectable byte (e.g. 13), auto-clear after N bytes, filter, timestamps (ms)
- Line break on LF, CR, CR+LF, time gap or after N bytes
- Send as ASCII (escapes `\n \r \t \0 \\ \xNN`), hex, dec, bin; selectable line ending on Enter
- Command history: arrow up/down in the input field, history menu (clock icon) next to the field, "History n/count" display in the status bar, persists across relaunches (last 50)
- Send file, raw data capture to file, copy/export log
- Save/load profiles as JSON, settings are remembered automatically

## Scripts (JavaScript)

Via the "Script" toolbar button. Scripts run on their own thread, so `sleep` and `waitFor` block normally.

| Function | Meaning |
| --- | --- |
| `send(text)` | Send text (JS escapes like `"\r\n"` work) |
| `sendHex("AA BB")` | Send bytes from hex |
| `sendBytes([1,2,3])` | Send bytes from an array |
| `waitFor(text, timeoutMs)` | Waits for text; returns received text up to and including the match, or `null` |
| `sleep(ms)` | Pause |
| `flush()` / `received()` | Clear / take the entire script receive buffer |
| `log(x)`, `clear()`, `connected()` | Print to terminal, clear terminal, connection status |

Example:

    flush();
    send("AT\r\n");
    if (waitFor("OK", 2000) === null) log("Timeout");

## Acknowledgements: HTerm

Hardterm would not exist without **[HTerm](https://www.der-hammer.info/pages/terminal.html)** by **Tobias Hammer**.

For many years, HTerm has been the go-to tool for anyone working with serial interfaces: microcontroller tinkerers, embedded developers, hardware engineers and students alike. Its brilliance lies in a rare combination: it shows exactly what is happening on the wire — byte by byte, in ASCII, hex, decimal and binary side by side — while remaining fast, lightweight and refreshingly free of clutter. Counters, flexible line breaks, sending in any number format, control line handling: everything you need when a board refuses to talk is right there, one click away. And it has been given to the community for free.

The layout of Hardterm's serial tab — connection bar, counters, output options, received data, input options, input, sent data — is a deliberate homage to HTerm's thoughtful design. Hardterm is simply an attempt to bring that experience natively to macOS.

Thank you, Tobias, for a tool that has saved countless hours of debugging and set the standard for what a serial terminal should be.

*Hardterm is an independent project and is not affiliated with or endorsed by HTerm or its author.*

## Structure

- `SerialPort.swift` termios, reading/writing, control lines
- `Session.swift` state, line buffer, sending, capture, script start
- `ScriptRunner.swift` JavaScriptCore bridge
- `Formatting.swift` display and input parsers
- `ContentView.swift` UI
