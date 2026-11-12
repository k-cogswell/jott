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
    /// True when the fetch limit cut off results Jira still had more of.
    var truncated: Bool?
    var limit: Int?
}

struct JiraJQL: Decodable {
    var ok: Bool
    var jql: String?
    var isDefault: Bool?
    var matched: Int?
    var matchedExact: Bool?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok, jql, matched, error
        case isDefault = "is_default"
        case matchedExact = "matched_exact"
    }

    /// "21" / "100+" -- the search endpoint returns no total, so a full page
    /// of results means "at least this many".
    var matchedDescription: String? {
        guard let matched else { return nil }
        return matchedExact == false ? "\(matched)+" : "\(matched)"
    }
}

/// The connection settings themselves, complete or not: site, account
/// email, and the cloud id that scoped tokens are routed through. Read and
/// written through `jott jira setup`, so config.toml keeps exactly one
/// writer -- the CLI -- and its comments survive being edited from the app.
struct JiraConnection: Decodable {
    var ok: Bool
    var configured: Bool?
    var site: String?
    var email: String?
    var cloudId: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok, configured, site, email, error
        case cloudId = "cloud_id"
    }

    static let empty = JiraConnection(ok: false, configured: false)
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
        /// The query matched more issues than the limit allowed. Surfaced
        /// rather than dropped: an issue missing from autocomplete because
        /// it sorted past the limit looks exactly like a broken query.
        var truncated = false
        var limit: Int?
        /// Jira is optional: absent configuration is not an error state.
        var isConfigured: Bool { !issues.isEmpty || error != nil }

        var truncationWarning: String? {
            guard truncated else { return nil }
            return "Showing the first \(issues.count) issues — your query matches more. "
                 + "Narrow the JQL, or raise jira_issue_limit in config.toml."
        }
    }

    /// Reads the configured site/account without touching the network.
    static func connection() -> JiraConnection {
        decodeConnection(JottCLI.run(["jira", "setup", "--json"]).output)
    }

    /// Writes the connection settings. The CLI normalises them (a site URL
    /// pasted from the browser becomes an origin), rejects what cannot work,
    /// and drops the issue cache when anything changed -- so what comes back
    /// is what is now on disk, not what was typed.
    static func saveConnection(site: String, email: String, cloudId: String) -> JiraConnection {
        decodeConnection(JottCLI.run(["jira", "setup", "--json",
                                      "--site", site,
                                      "--email", email,
                                      "--cloud-id", cloudId]).output)
    }

    private static func decodeConnection(_ output: String) -> JiraConnection {
        guard let data = output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JiraConnection.self, from: data) else {
            return JiraConnection(ok: false, configured: false,
                                  error: output.isEmpty ? "No response from the jott CLI." : output)
        }
        return decoded
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

    /// Reads the active JQL. Needs no credentials, so it works even before
    /// a token is stored.
    static func jql() -> JiraJQL {
        decodeJQL(JottCLI.run(["jira", "jql", "--json"]).output)
    }

    /// Validates a query against Jira and persists it on success. The CLI
    /// drops the issue cache as part of saving, so the next read refetches
    /// rather than serving the old query's results.
    static func setJQL(_ query: String) -> JiraJQL {
        decodeJQL(JottCLI.run(["jira", "jql", query, "--json"]).output)
    }

    static func resetJQL() -> JiraJQL {
        decodeJQL(JottCLI.run(["jira", "jql", "--reset", "--json"]).output)
    }

    private static func decodeJQL(_ output: String) -> JiraJQL {
        guard let data = output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JiraJQL.self, from: data) else {
            return JiraJQL(ok: false,
                           error: output.isEmpty ? "No response from the jott CLI." : output)
        }
        return decoded
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
                            stale: decoded.stale ?? false,
                            truncated: decoded.truncated ?? false,
                            limit: decoded.limit)
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
