<div align="center">
  <img src="assets/logo.png" alt="Jott Logo" width="400" />

  <br/>

  **A minimal, terminal-centric time tracker designed for developers who live in `vim` and `tmux`.**
</div>

<br/>
 Jott automatically compiles beautifully formatted, write-cached Markdown tables directly on input, features intelligent chronological sorting, and can sync data pipelines seamlessly up to Google Drive via `rclone`.

By compiling human-readable summary metrics directly into standard Markdown, your historical timeline ledgers double as self-contained, finalized text logs. Open them directly in GitHub, Obsidian, or Vim without fighting specialized formats or database corruptions.

---

## ✨ Features

- ⌨️ **Keyboard Native:** Log your tasks instantly without leaving your shell.
- ⚡ **Write-Cached Architecture:** Pre-computes and bakes summary ledger tables straight to the Markdown file when a task triggers.
- 🎨 **Smart Terminal Presentation:** Strips and overlays high-contrast ANSI themes on the fly when viewing files through the CLI, keeping disk text completely clean.
- ⏱️ **Live Status Tracking:** Displays active running metrics and live session tracking on query.
- ⏳ **Retroactive Logging (Backlog):** Forgot to log a meeting? Insert a task that kicked off a given number of minutes ago. The engine resolves chronologies automatically.
- 🔄 **Smart Resumption (Continue):** Continue your last task raw, or supply a historical table integer ID (`jott continue 2`) to clone any historical entry forward instantly.
- 📆 **Weekly Timesheet Aggregation:** Run `jott week` on Friday afternoons to view a high-level matrix mapping exact hour values per day for effortless entry into external corporate tools like OpenAir.
- ⚙️ **XDG Standard Configuration:** Cleanly houses modular file target outputs through central TOML controls.

<br>

---
## 🚀 Quick Start & Installation (Private Tap)

Deploy this package using a clean Homebrew installation flow.

### 1. Installation
```bash
brew tap k-cogswell/tap
brew install jott
```

### 2. Basic Usage Cadence

```bash
jott "skyalyne-2080 - bruno review"   # Kicks off a new task tracking block
jott status                           # Queries active runtime metrics
jott break                            # Pauses tracking time metrics
jott continue                         # Resumes last active workflow
jott week                             # Generates a timesheet lookup grid
```

---

## ⚙️ Configuration

`jott` complies with the modern XDG Base Directory Specification. The first time you execute the script, it automatically generates a zero-dependency configuration file at:
`~/.config/jott/config.toml`

By default, it initializes your workspace to funnel all timeline text vault logs into a global home directory folder (`~/.jott`).

### Customizing the Log Directory

If you prefer to direct your archives folder somewhere else (such as a shared server directory or an explicit local folder inside your Git workspace profile), open the configuration file:

```bash
vim ~/.config/jott/config.toml
```

Simply update the `log_dir` variable string to target your desired path. Tilde (`~`) home shorthand paths are fully supported:

```toml
# 🕒 Jott CLI Configuration File
# You can change where your markdown log archives are saved below:

log_dir = "~/projects/my-time-vault/archives"
```

---

## 💡 Detailed Usage Guide

### Retroactive Logging (The "I Forgot" Feature)

If you get pulled away into an unscheduled meeting or hotfix and forget to punch it into your terminal, log it retroactively after the fact by specifying how many minutes ago the task started:

```bash
jott backlog 30 "Emergency Sync with team"
```

### Table ID Line Continuation

To return to a specific task you tackled earlier in the day without re-typing or copy-pasting its string contents, query your ledger table via `jott view`, identify its integer row position ID, and reference it:

```bash
jott continue 1
# Output: Recorded: skyalyne-2080 - bruno review
```

#### Render View Grid Layout Example:

```text
## Time Summary for Monday, June 1st, 2026 (2026-06-01)

| ID | Start    | End                 | Duration | Task               |
| -- | -------- | ------------------- | -------- | ------------------ | 
| 1  | 09:00:00 | 10:00:00            | 1h 0m    | Refactoring schema |
| 2  | 10:00:00 | 10:30:00            | 30m      | break              |
| 3  | 10:30:00 | 11:30:00            | 1h 0m    | Emergency meeting  |
| 4  | 11:30:00 | 12:45:10 (current)  | 1h 15m   | Reviewing PRs      |
└── Total Logged Hours: 3h 15m
```

---

## 📁 Storage & Markdown Structure

### Repository Tree Structure

The logs generate nested subfolders automatically using a year/month/day structure to keep your data vaults organized:

```text
~/.jott/
└── 2026/
    └── 06/
        └── 2026-06-01.md
```

### Under the Hood: The Raw Markdown Layout

Because the script bakes the report summaries as pure text on disk, running a direct file query like `cat ~/.jott/2026/06/2026-06-01.md` reveals a completely clean format entirely free of hidden ANSI escape noise:

```markdown
# Time Log: 2026-06-01
- 09:00:00 | Refactoring the user auth database schema
- 10:00:00 | break
- 10:30:00 | Emergency Sync with DevOps team
- 11:30:00 | Reviewing Pull Requests

## Summary Report
Date: Monday, June 1st, 2026

| ID | Start    | End      | Duration | Task                                     |
| -- | -------- | -------- | -------- | ---------------------------------------- |
| 1  | 09:00:00 | 10:00:00 | 1h 0m    | Refactoring the user auth database schema|
| 2  | 10:00:00 | 10:30:00 | 30m      | break                                    |
| 3  | 10:30:00 | 11:30:00 | 1h 0m    | Emergency Sync with DevOps team          |
| 4  | 11:30:00 | -        | -        | Reviewing Pull Requests                  |

└── Total Logged Hours: 2h 0m
```

---

## ☁️ Cloud Sync & rclone Setup (WIP)

Back up your metrics vault cleanly to a private cloud instance like Google Drive using `rclone`. `jott` features a native `sync` command to run this backup pipeline.

### 1. Install rclone

```bash
brew install rclone
```

### 2. Configure the Cloud Remote

Execute the interactive backend assistant:

```bash
rclone config
```

Follow the prompts exactly as outlined below:

1. Choose **`n`** for a *New remote*.
2. Name the remote target identifier explicitly: **`gdrive`**.
3. Select **`Google Drive`** from the driver list selection menu.
4. Leave `client_id` and `client_secret` **blank** to use core system defaults.
5. Choose scope **`1`** (Full access allocation).
6. Leave root folders and credentials file pointers **blank**.
7. Opt **`n`** for advanced parameter overrides.
8. Select **`y`** for auto-config. Grant validation permissions in your browser.
9. Review and save configuration records with **`y`**.

### 3. Execution & Automation

Synchronize your logs manually at any time by executing:

```bash
jott sync
```

To run your backup automatically in the background at the end of every workday, open your local cron scheduler (`crontab -e`) and map an optimization instruction pointing to your target data vault folder:

```text
0 18 * * 1-5 rclone sync /Users/username/.jott gdrive:JottBackupVault
```
