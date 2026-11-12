import Foundation

// ======================================================================
// WRITE PATH
// ======================================================================
// Every mutation shells out to the Python CLI. Nothing in this app
// appends to a ledger or regenerates a summary table itself -- that
// logic lives in exactly one place, src/commands.py.
enum JottCLI {
    static let cliPathDefaultsKey = "cliPath"

    /// Resolution order: explicit setting -> conventional install locations.
    /// install.sh writes the setting directly, so this normally hits case 1.
    static func resolvePath() -> String? {
        if let configured = UserDefaults.standard.string(forKey: cliPathDefaultsKey),
           FileManager.default.fileExists(atPath: configured) {
            return configured
        }
        let candidates = [
            "/opt/homebrew/bin/jott",
            "/usr/local/bin/jott",
            NSString(string: "~/.local/bin/jott").expandingTildeInPath,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    struct Result {
        var output: String
        var succeeded: Bool
    }

    /// Runs the CLI with the given arguments. If the script has lost its
    /// executable bit we fall back to invoking python3 against it -- the
    /// CLI is pure stdlib, so the interpreter shipped with the Command
    /// Line Tools is always sufficient.
    @discardableResult
    static func run(_ args: [String], input: String? = nil) -> Result {
        guard let path = resolvePath() else {
            return Result(output: "Could not find the jott CLI. Set its path in Settings.", succeeded: false)
        }

        let process = Process()
        let isExecutable = FileManager.default.isExecutableFile(atPath: path)
        if isExecutable {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [path] + args
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let stdinPipe = Pipe()
        if input != nil { process.standardInput = stdinPipe }

        do {
            try process.run()
        } catch {
            return Result(output: "Failed to launch jott: \(error.localizedDescription)", succeeded: false)
        }

        if let input {
            stdinPipe.fileHandleForWriting.write(Data(input.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var text = String(data: data, encoding: .utf8) ?? ""
        text = stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(output: text, succeeded: process.terminationStatus == 0)
    }

    static func log(_ task: String) -> Result { run([task]) }
    static func stop() -> Result { run(["stop"]) }
    static func continueLast() -> Result { run(["continue"]) }

    /// Retroactive entry: `jott backlog [minutes] "task"`.
    static func backlog(minutes: Int, task: String) -> Result {
        run(["backlog", String(minutes), task])
    }

    /// Bulk-replaces a day's entries. `lines` are 'HH:MM:SS | task'.
    /// The CLI validates every line before touching the file, so a
    /// malformed set fails without destroying what is already logged.
    static func rewrite(lines: [String], date: String? = nil) -> Result {
        var args = ["rewrite"]
        if let date { args.append(date) }
        return run(args, input: lines.joined(separator: "\n") + "\n")
    }

    /// The CLI paints its output with ANSI colour for the terminal;
    /// strip it before showing text in a notification or the UI.
    private static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]",
                               with: "",
                               options: .regularExpression)
    }
}
