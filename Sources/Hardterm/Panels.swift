import AppKit
import UniformTypeIdentifiers

@MainActor
enum Panels {
    static func open(types: [UTType] = []) -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        if !types.isEmpty { p.allowedContentTypes = types }
        return p.runModal() == .OK ? p.url : nil
    }

    static func save(name: String) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
