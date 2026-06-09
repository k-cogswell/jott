<div align="center">
  <img src="assets/logo.png" alt="Jott Logo" width="400" />

  <br/>

  **A minimal time tracker designed for developers who live in the terminal.**
</div>

<br/>
 Jott automatically compiles beautifully formatted, write-cached Markdown tables directly on input, features intelligent chronological sorting, and can sync data pipelines seamlessly up to Google Drive via `rclone`.

By compiling human-readable summary metrics directly into standard Markdown, your historical timeline ledgers double as self-contained, finalized text logs. Open them directly in GitHub, Obsidian, or Vim without fighting specialized formats or database corruptions.

## ✨ Features

* ⌨️ **Keyboard Native:** Log tasks instantly without leaving your active project shell buffer.
* ⚡ **Write-Cached Engine:** Pre-computes and bakes optimized summary ledger tables into Markdown automatically on input.
* 🎨 **Dynamic Presenter:** Applies high-contrast ANSI colors on-the-fly inside the terminal while keeping on-disk Markdown completely clean.
* ⏳ **Retroactive Correction:** Insert tasks that started a given number of minutes ago. Chronologies are resolved and re-sorted instantly.
* 🔄 **Smart Resumption:** Clone previous tasks forward by passing its raw line position integer ID number.
* 📆 **Timesheet Aggregator:** Instantly maps accurate, breakout-free hour values per day for fast transcription into external corporate tools like OpenAir.
* ⚙️ **XDG Standard Compliance:** Isolate your configuration files and target file directories using standardized TOML layout schemes.

---

## 🚀 Installation & Homebrew Setup

Deploy `jott` natively to your development machine using your custom Homebrew tap:

```bash
# 1. Tap your private or public team repository space
brew tap your-github-username/tap

# 2. Install the binary globally
brew install jott

```

---

## ⚙️ Configuration

`jott` complies with the modern XDG Base Directory Specification. The first time you execute a command, it automatically generates a baseline configuration file at:
`~/.config/jott/config.toml`

By default, it routes your daily database text files into a global home vault directory located at `~/.jott`.

### Modifying the Active Log Path

If you prefer to direct your daily files inside an active shared company server drive or a dedicated workspace folder inside your active Git repository, modify your file:

```bash
nvim ~/.config/jott/config.toml
```

Simply update the `log_dir` target path variable string. Tilde (`~`) user expansions are fully supported:

```toml
# 🕒 Jott CLI Configuration File
# You can change where your markdown log archives are saved below:
log_dir = "~/projects/my-time-vault/archives"
```

Verify your resolved setup at any time by executing `jott help`. It will echo your exact active operational files right at the top of the context summary display.

---

## 🗺️ Detailed Usage Guide: A Day in the Life

To get comfortable with the complete `jott` command suite, let's walk through how a typical developer uses it step-by-step from morning check-in to end-of-week timesheet submission.

### 🌅 09:00 AM — Punching In

You sit down at your keyboard and kick off your day with your first engineering meeting. To start tracking time, call `jott` followed by your message:

```bash
jott "Sprint Planning & Team Standup"
# Output: Recorded: Sprint Planning & Team Standup
```

Behind the scenes, `jott` creates today's calendar Markdown ledger and opens a line item recording that your task began exactly at `09:00:00`.

### 🔍 09:45 AM — Checking Active Status

You want to verify what task you are currently billing time to and see how long you've been working on it without rendering a giant text grid. Run the tool raw (or pass the explicit `status` modifier):

```bash
jott
# Output: Current Task: Sprint Planning & Team Standup (Running for 45m)
```

### ⚙️ 10:00 AM — Shifting Gears

Standup ends, and it's time to dive into technical focus blocks. You log your next project milestone:

```bash
jott "pr review"
# Output: Recorded: pr review
```

> **How Jott's Engine Works:** You never have to manually clock out of a task. The moment you input a new task description, `jott` intercepts the command, marks `10:00:00` as the completion time for your standup meeting, calculates that the meeting took exactly `1h 0m`, and initializes your new engineering clock.

### ☕ 12:00 PM — Stepping Away

It's lunchtime, and you want to freeze your project tracking metrics so you don't accidentally bill time to a client or internal ticket. Pass any structural tracking pause keyword (`break`, `stop`, or `end`):

```bash
jott break
# Output: Recorded: break
```

The calculation algorithm marks the completion of your review task and stops the active tracking timer.

### 🪵 01:30 PM — The Retroactive "Oops"

You sit back down at `01:30 PM` after lunch, but realize you were pulled into an urgent production infrastructure emergency at `01:00 PM` and forgot to log it.

Instead of opening your raw ledger file to fix the timestamps manually, handle it directly from your terminal using the `backlog` command followed by the number of minutes ago the task *actually* started:

```bash
jott backlog 30 "DevOps infrastructure hotfix"
# Output: Recorded: (backdated to 2026-06-09) DevOps infrastructure hotfix
```

`jott` calculates the relative backward time offset (`13:30 minus 30 minutes = 13:00`), inserts the hotfix cleanly at `13:00:00`, and marks your lunch break as a crisp 60-minute interval.

### 🔄 02:00 PM — Re-engaging Earlier Focus Blocks

The hotfix is wrapped up, and you want to jump back into code review from this morning. Instead of re-typing or copy-pasting that long task description string, print today's dashboard layout:

```bash
jott view
```

```text
## Time Summary for Tuesday, June 9th, 2026 (2026-06-09)

| ID | Start    | End                 | Duration | Task                                    |
| -- | -------- | ------------------- | -------- | --------------------------------------- |
| 1  | 09:00:00 | 10:00:00            | 1h 0m    | Sprint Planning & Team Standup          |
| 2  | 10:00:00 | 12:00:00            | 2h 0m    | pr review                               |
| 3  | 12:00:00 | 13:00:00            | 1h 0m    | break                                   |
| 4  | 13:00:00 | 14:00:00            | 1h 0m    | DevOps infrastructure hotfix            |
└── Total Logged Hours: 4h 0m
```

You see that the review block is sitting right at row **`ID 2`**. Clone it forward instantly using the row index identifier:

```bash
jott continue 2
# Output: Recorded: pr review
```

*(Pro-Tip: If you take a brief 5-minute break and just want to resume the absolute last thing you were working on, simply run `jott continue` without an ID number).*

### 📝 04:30 PM — Correcting Mistakes (Manual Intervention)

You realize that row `ID 4` shouldn't have been logged as "infrastructure hotfix"—it was actually an "architecture sync meeting." You want to fix the raw data directly. Execute the `edit` command:

```bash
jott edit
```

This suspends your active shell environment and launches Neovim directly into today's log file. You modify line 4:

```text
# Before
- 13:00:00 | DevOps infrastructure hotfix

# After
- 13:00:00 | DevOps architecture sync
```

Type `:wq` to save and close out of Neovim.

> **Automatic Cache Recalculation:** The moment Neovim closes, `jott` catches the file change handle, completely parses your raw lines, re-sequences the chronologies, and completely regenerates the output report summary table and hours tallies perfectly in the background.

### 📊 05:00 PM — Friday Afternoon OpenAir Entry

It's the end of the week, and you need to submit your time metrics into your company's official management software (OpenAir). Instead of running `jott view` five individual times and clicking through calendar panels, load your high-level weekly matrix:

```bash
jott week
```

```text
🗓️  Weekly Timesheet Matrix (Week of 2026-06-08)

| Day        | Date         | Total Hours  |
| ---------- | ------------ | ------------ |
| Monday     | 2026-06-08   | 8h 15m       |
| Tuesday    | 2026-06-09   | 7h 45m       |
| Wednesday  | 2026-06-10   | 8h 0m        |
| Thursday   | 2026-06-11   | 8h 30m       |
| Friday     | 2026-06-12   | 4h 15m       |
| Saturday   | 2026-06-13   | -            |
| Sunday     | 2026-06-14   | -            |
└── Grand Total Weekly Hours: 37h 45m

🔍 Itemized Task Notes Reference:

### Tuesday (2026-06-09)
  • [09:00:00 - 10:00:00] (1h 0m) → Sprint Planning & Team Standup
  • [10:00:00 - 12:00:00] (2h 0m) → pr review
  • [13:00:00 - 14:00:00] (1h 0m) → DevOps architecture sync
  • [14:00:00 - 17:15:00] (3h 15m) → pr review
```

You copy the daily totals directly into your timesheet cells. The *Itemized Task Notes* section automatically strips out your breaks and lunch periods, leaving a pristine list of descriptions ready to paste into your billing logs.

#### What if I forgot to enter my time and it's now next week?

No problem. You can pass lookback modifiers to dive backwards through historical weekly blocks:

```bash
jott week last        # Pulls up the entire matrix for last week
jott week 2           # Pulls up the matrix for two weeks ago
jott week 2026-05-18  # Pulls up the week containing that specific date

```

### ☁️ 05:15 PM — Offsite Backup

Your timesheet is approved, and your week is wrapped up. Run the native cloud connector to safely sync your text data logs directory up to your secure Google Drive storage layout via `rclone`:

```bash
jott sync
# Output: ✨ Backup successful! Your logs are secure in the cloud.
```

---

## 📁 Storage Layout Vault Overview

Your data directory generates organized path branches using a simple nested execution tree format:

```text
~/.jott/
└── 2026/
    └── 06/
        └── 2026-06-09.md    <- Pristine, raw human-readable log file
```

### Public GitHub Repositories Safeguard (Pro-Tip)

If you configure your `config.toml` file to route your log directory directly inside a public code repository, add your vault folder path to your master `.gitignore` list to avoid pushing confidential client tickets to the public internet:

```text
# .gitignore
archives/
.jott/
```

```
```
