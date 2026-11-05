import Foundation

/// Lokalisierte Zeichenkette. Schlüssel ist der deutsche Originaltext, die Übersetzungen
/// stehen in Resources/<sprache>.lproj/Localizable.strings. Mit Format-Argumenten (%@, %lld).
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
