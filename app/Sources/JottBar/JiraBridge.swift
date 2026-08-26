import Foundation

// ======================================================================
// JIRA (READ PATH, VIA THE CLI)
// ======================================================================
// The app does not talk to Jira directly. It shells out to
// `jott jira issues --json`, so the HTTP client, auth, Keychain access
// and caching all live in one place -- src/jira.py -- and the terminal
// gets the same feature set.

struct JiraIssue: Identifiable, Equatable, Decodable {
    var key: String
    var summary: String
    var status: String

    var id: String { key }
    /// What actually gets logged when you pick this issue.
    var taskText: String { summary.isEmpty ? key : "\(key) \(summary)" }
}

private struct JiraIssuesResponse: Decodable {
    var ok: Bool
    var issues: [JiraIssue]
    var stale: Bool?
    var error: String?
}

struct JiraStatus: Decodable {
    var ok: Bool
    var configured: Bool?
    var site: String?
    var email: String?
    var mode: String?
    var jql: String?
    var tokenStored: Bool?
    var valid: Bool?
    var displayName: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok, configured, site, email, mode, jql, error
        case tokenStored = "token_stored"
        case valid
        case displayName = "display_name"
    }

    static let unknown = JiraStatus(ok: false, configured: false, error: nil)
}

enum JiraBridge {
    struct Snapshot {
        var issues: [JiraIssue] = []
        var error: String?
        var stale = false
        /// Jira is optional: absent configuration is not an error state.
        var isConfigured: Bool { !issues.isEmpty || error != nil }
    }

    /// Reads connection state. Never returns or logs the token itself.
    static func status() -> JiraStatus {
        let result = JottCLI.run(["jira", "status", "--json"])
        guard let data = result.output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JiraStatus.self, from: data) else {
            return JiraStatus(ok: false, configured: false,
                              error: result.output.isEmpty ? nil : result.output)
        }
        return decoded
    }

    /// Hands the token to `jott jira login --stdin`, which verifies it and
    /// writes it to the Keychain. The app never touches the Keychain itself,
    /// and never persists the token anywhere of its own.
    static func connect(token: String) -> (ok: Bool, message: String) {
        let result = JottCLI.run(["jira", "login", "--stdin"], input: token)
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, result.output.isEmpty ? "No response from the jott CLI." : result.output)
        }
        if json["ok"] as? Bool == true {
            return (true, "Connected as \(json["display_name"] as? String ?? "your account").")
        }
        return (false, json["error"] as? String ?? "Could not connect.")
    }

    static func disconnect() {
        JottCLI.run(["jira", "logout"])
    }

    static func issues(refresh: Bool = false) -> Snapshot {
        var args = ["jira", "issues", "--json"]
        if refresh { args.append("--refresh") }

        let result = JottCLI.run(args)
        guard let data = result.output.data(using: .utf8) else {
            return Snapshot(error: "Could not read the CLI response.")
        }

        do {
            let decoded = try JSONDecoder().decode(JiraIssuesResponse.self, from: data)
            return Snapshot(issues: decoded.issues,
                            error: decoded.error,
                            stale: decoded.stale ?? false)
        } catch {
            // A non-JSON body means the CLI failed before it could emit one.
            let text = result.output.isEmpty ? "No response from the jott CLI." : result.output
            return Snapshot(error: text)
        }
    }
}

// ----------------------------------------------------------------------

/// One row in the capture prompt's completion list.
struct Suggestion: Identifiable {
    enum Kind { case recent, jira }

    var kind: Kind
    /// Text inserted into the ledger when chosen.
    var taskText: String
    var key: String?
    var detail: String?

    var id: String { (key ?? "") + "|" + taskText }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        if taskText.lowercased().contains(q) { return true }
        if let key, key.lowercased().contains(q) { return true }
        return false
    }
}
