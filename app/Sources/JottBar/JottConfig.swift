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

    /// Resolves the active log directory. Deliberately re-read on demand
    /// rather than cached, so editing config.toml takes effect without a relaunch.
    static func logBaseDir() -> String {
        guard let text = try? String(contentsOfFile: configFile, encoding: .utf8) else {
            return defaultLogDir
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "log_dir" else { continue }
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !val.isEmpty { return NSString(string: val).expandingTildeInPath }
        }
        return defaultLogDir
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
