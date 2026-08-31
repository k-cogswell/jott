# Jott

A terminal time tracker (Python CLI) plus **JottBar**, a macOS menubar companion (Swift/SwiftUI).
Ledgers are plain Markdown files on disk — there is no database.

## Layout

| Path | What it is |
| --- | --- |
| `jott` | CLI entrypoint. Argument routing only; all behaviour lives in `src/`. |
| `src/commands.py` | Every user-facing command. The largest file; start here. |
| `src/storage.py` | Ledger file paths, parsing, duration math, report regeneration. |
| `src/config.py` | `~/.config/jott/config.toml` read/write (hand-rolled TOML subset). |
| `src/jira.py` | Jira Cloud REST client, Keychain token storage, 15-min issue cache. |
| `src/helpers.py` | Duration/date formatting. |
| `app/Sources/JottBar/` | The menubar app. |
| `install.sh` / `uninstall.sh` | Build, bundle, sign, and install `JottBar.app`. |

## Data model

A ledger is `<log_dir>/YYYY/MM/YYYY-MM-DD.md`, defaulting to `~/.jott`.

```markdown
# Time Log: 2026-08-31
- 09:00:00 | Sprint Planning
- 10:00:00 | pr review
- 12:00:00 | break

## Summary Report          <- everything from here down is GENERATED
...
```

**Only the `- HH:MM:SS | task` lines are source of truth.** Everything below `## Summary Report`
is derived output, rewritten from scratch by `generate_and_save_report()` on every mutation.
Both parsers (`storage.parse_log`, `Ledger.parse`) read the `- ` lines and ignore the rest.

### Invariants

- **Entries have no end time.** A row's duration is the gap to the *next* entry's start. The last
  entry of a past day therefore counts as zero — `storage.is_unclosed()` exists to warn about it.
- **Timestamps are sorted as strings**, so they must be zero-padded `HH:MM:SS`. `9:00:00` would sort
  after `10:00:00` and scramble the day. `rewrite_ledger` normalises via `strptime` for this reason.
- **`stop` / `break` / `end` are break sentinels** — matched case-insensitively, excluded from totals.
  The set is defined in `src/storage.py`, repeated in `src/commands.py`, and mirrored in
  `app/Sources/JottBar/Ledger.swift:14`. Change one, change all three.
- **Any write must be followed by `generate_and_save_report(date)`**, or the on-disk table goes stale.
- Ledgers hold real, unrecoverable time-tracking data. Treat writes to `~/.jott` as destructive.

## The CLI/app boundary

The app **reads** ledgers directly (`Ledger.swift`, mirroring the Python parser for responsiveness)
but **never writes** them. Every mutation shells out through `JottCLI.run()` to the Python CLI, so
file layout and report generation live in exactly one place. Keep it that way — do not add file
writes to Swift.

The two sides talk over `--json` on stdout. These are load-bearing contracts; renaming a key breaks
a Swift `Decodable` silently at runtime:

| CLI command | Swift consumer |
| --- | --- |
| `jott find <text> --limit N --json` | `HistorySearch.swift` |
| `jott jira setup/status/jql --json` | `JiraBridge.swift` |
| `jott jira issues --json` | `JiraBridge.swift` |
| `jott rewrite <date>` (entries on stdin) | `LogEditorView.swift` via `LedgerStore` |

`src/config.py` and `app/Sources/JottBar/JottConfig.swift` are deliberate duplicates of the same
config parse + path resolution. Edit both together.

## Building and running

Python: **3.9** (the one shipped with Xcode Command Line Tools), **stdlib only**. No venv, no
`requirements.txt`, no build step — do not introduce a third-party dependency; the Homebrew/CLT
install path depends on there being none.

```bash
./jott help                 # CLI runs straight from the checkout
cd app && swift build       # typecheck/build the app (debug)
./install.sh                # release build + bundle + ad-hoc sign + install to ~/Applications
```

`install.sh` assembles the `.app` by hand — there is no Xcode project, and that is intentional
(Command Line Tools alone suffice). The bundle id `com.kylecogswell.jottbar` is stable; changing it
orphans preferences, the login item, and granted permissions.

After a Swift change, `cd app && swift build` is the fast check. Only run `./install.sh` when the
user actually wants the running app replaced — it quits their live instance and relaunches.

## Testing

There is no test suite. **Never smoke-test the CLI against the real `~/.jott`** — it would write
into the user's actual time records. Both the config dir and default log dir derive from `$HOME`,
so override it:

```bash
SANDBOX=$(mktemp -d)
HOME=$SANDBOX ./jott "test entry"
HOME=$SANDBOX ./jott backlog 30 "earlier thing"
HOME=$SANDBOX ./jott view
cat $SANDBOX/.jott/*/*/*.md
```

That isolates every write to the sandbox. Reading the user's real ledgers is fine; writing is not.
`jott sync` (rclone to Google Drive) and the `jira` subcommands hit the network — leave them alone
unless the task is about them.

## Conventions

- Conventional Commits with a scope: `feat(app):`, `fix(cli):`, `feat(jira):`, `chore:`, `docs:`.
- Comments explain **why**, not what — see `_unquote` in `src/config.py` or `is_unclosed` in
  `src/storage.py`. Banner comments (`# ===== SECTION =====`) mark major sections in the Python
  files and `// =====` in Swift. Match the surrounding density rather than adding narration.
- Terminal output uses the `CLR_*` ANSI constants from `src/config.py`. Colour is applied at print
  time only — **on-disk Markdown stays clean**, never write escape codes into a ledger.
- Config writes go through `set_setting`/`unset_setting`, which rewrite a single line atomically.
  `config.toml` is hand-maintained and full of comments; never rewrite the whole file.
