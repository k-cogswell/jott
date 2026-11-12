import Foundation

// ======================================================================
// SHARED CONFIGURATION SURFACE
// ======================================================================
// Mirrors src/config.py so the menubar app and the CLI always agree on
// where the markdown ledgers live. Same light TOML token scan, same
// tilde expansion, same fallback to ~/.jott.
enum JottConfig {
    static let configDir = NSString(string: "~/.config/jott").expandingTildeInPath
    static var configFile: String { (configDir as NSString).appendingPathComponent("config.toml") }
    static let defaultLogDir = NSString(string: "~/.jott").expandingTildeInPath

    /// Reads one key. Deliberately re-read on demand rather than cached,
    /// so editing config.toml takes effect without a relaunch.
    /// Mirrors config.get_setting: same token scan, same comment skipping.
    static func setting(_ wanted: String) -> String? {
        guard let text = try? String(contentsOfFile: configFile, encoding: .utf8) else {
            return nil
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard key == wanted else { continue }
            let val = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return val.isEmpty ? nil : val
        }
        return nil
    }

    /// Resolves the active log directory.
    static func logBaseDir() -> String {
        guard let val = setting("log_dir") else { return defaultLogDir }
        return NSString(string: val).expandingTildeInPath
    }

    /// Minimum entry length, in seconds. 0 disables the rule.
    /// Mirrors storage.get_min_entry_seconds, bounds included -- the two
    /// sides must agree or the app would gate a Save the CLI accepts.
    static func minEntrySeconds() -> Int {
        guard let raw = setting("min_entry_minutes"), let minutes = Int(raw) else {
            return 5 * 60
        }
        return max(0, min(minutes, 120)) * 60
    }

    /// [LOG_BASE_DIR]/YYYY/MM/YYYY-MM-DD.md -- matches storage.get_file_path.
    static func filePath(for date: Date) -> String {
        let base = logBaseDir()
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        let year = f.string(from: date)
        f.dateFormat = "MM"
        let month = f.string(from: date)
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        return URL(fileURLWithPath: base)
            .appendingPathComponent(year)
            .appendingPathComponent(month)
            .appendingPathComponent("\(day).md")
            .path
    }
}
