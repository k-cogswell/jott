import os
import sys
import json
import getpass
import subprocess
from datetime import datetime, timedelta
from .config import LOG_BASE_DIR, CONFIG_FILE, CLR_TITLE, CLR_HEAD, CLR_CMD, CLR_TEXT, CLR_RESET, CLR_BOLD
from .helpers import format_duration, get_ordinal_date
from . import jira
from .storage import get_file_path, parse_log, calculate_daily_durations, generate_and_save_report, is_unclosed, iter_log_dates

def log_task(message, custom_dt=None):
    """Saves a fresh tracking row milestone directly to your historical logs."""
    target_dt = custom_dt if custom_dt else datetime.now()
    date_str = target_dt.strftime("%Y-%m-%d")
    time_str = target_dt.strftime("%H:%M:%S")
    file_path = get_file_path(date_str)
    
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    with open(file_path, "a") as f:
        f.write(f"- {time_str} | {message}\n")
        
    # Instantly trigger the summary recompilation layer on save
    generate_and_save_report(date_str)
    backdate_msg = f" (backdated to {date_str})" if custom_dt else ""
    print(f"Recorded: [{time_str}]{backdate_msg} {message}")

def edit_ledger(target_date):
    """
    Suspends script execution and hands terminal UI control over to Neovim.
    Once Neovim saves and closes, it intercepts the exit signal and 
    automatically re-compiles your files to fix any manual changes.
    """
    file_path = get_file_path(target_date)
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    
    if not os.path.exists(file_path):
        with open(file_path, "w") as f:
            f.write(f"# Time Log: {target_date}\n\n")

    print(f"{CLR_TITLE}📝 Opening ledger for {target_date} in Neovim...{CLR_RESET}")
    try:
        # Hand off control to the native terminal shell process context
        subprocess.run(["nvim", file_path], check=True)
        
        # Intercept on close and fix any calculation drifts caused by manual overrides
        generate_and_save_report(target_date)
        print(f"{CLR_CMD}✨ Save verified. Report table and hours compiled successfully for {target_date}.{CLR_RESET}")
    except FileNotFoundError:
        print(f"{CLR_TEXT}Error: 'nvim' binary executable was not found in your system path environment.{CLR_RESET}")
    except Exception as e:
        print(f"{CLR_TEXT}An error occurred executing your editor context: {e}{CLR_RESET}")

def rewrite_ledger(target_date):
    """
    Replaces every entry for a day with the set supplied on stdin, then
    recompiles the summary table. Reads `HH:MM:SS | task` lines -- the same
    shape parse_log produces, minus the leading '- ' marker.

    This is the write primitive the JottBar menubar app uses for in-app
    editing. Routing edits through here keeps on-disk layout and report
    generation owned by this module rather than duplicated in the app.
    """
    raw = sys.stdin.read()
    entries = []

    for lineno, line in enumerate(raw.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        if " | " not in line:
            print(f"Error: line {lineno} is not 'HH:MM:SS | task': {line}")
            sys.exit(1)

        time_str, message = line.split(" | ", 1)
        time_str, message = time_str.strip(), message.strip()

        # Validate before touching the file -- a partial write here would
        # destroy real tracked hours.
        try:
            # Normalise while validating. Entry lines are sorted as strings
            # everywhere in this codebase, so an unpadded hour like '9:00:00'
            # would sort after '10:00:00' and scramble the chronology.
            time_str = datetime.strptime(time_str, "%H:%M:%S").strftime("%H:%M:%S")
        except ValueError:
            print(f"Error: line {lineno} has an invalid timestamp '{time_str}'. Expected HH:MM:SS.")
            sys.exit(1)
        if not message:
            print(f"Error: line {lineno} has an empty task description.")
            sys.exit(1)

        entries.append((time_str, message))

    entries.sort(key=lambda e: e[0])
    file_path = get_file_path(target_date)
    os.makedirs(os.path.dirname(file_path), exist_ok=True)

    if not entries:
        # Every row was deleted. Drop the file rather than leave an orphaned
        # summary table describing nothing.
        if os.path.exists(file_path):
            os.remove(file_path)
        print(f"Cleared all entries for {target_date}.")
        return

    with open(file_path, "w") as f:
        f.write(f"# Time Log: {target_date}\n")
        for time_str, message in entries:
            f.write(f"- {time_str} | {message}\n")

    # Re-run the write-cached engine so the markdown table matches the edits
    generate_and_save_report(target_date)
    noun = "entry" if len(entries) == 1 else "entries"
    print(f"Updated {len(entries)} {noun} for {target_date}.")

def continue_previous_task(target_id=None):
    """
    Resumes a task. It either crawls back sequentially to find your 
    last tracked task or performs a direct key lookup on a table row ID.
    """
    today_str = datetime.now().strftime("%Y-%m-%d")
    entries = parse_log(get_file_path(today_str))
    
    if not entries:
        print(f"{CLR_TEXT}Error: No tasks logged yet today to continue.{CLR_RESET}")
        return

    target_task = None
    if target_id is not None:
        # Branch 1: Explicit Table row position number lookup
        try:
            idx = int(target_id) - 1
            if 0 <= idx < len(entries):
                target_task = entries[idx]["message"]
            else:
                print(f"{CLR_TEXT}Error: ID '{target_id}' is out of bounds for today's logs.{CLR_RESET}")
                return
        except ValueError:
            print(f"{CLR_TEXT}Error: Continue target parameter must be an integer row ID.{CLR_RESET}")
            return
    else:
        # Branch 2: Search backward through logs to skip break/stop keywords
        for entry in reversed(entries):
            if entry["message"].lower() not in ["stop", "break", "end"]:
                target_task = entry["message"]
                break

    if not target_task:
        print(f"{CLR_TEXT}Error: No valid work blocks found to continue from today.{CLR_RESET}")
        return

    # Guard tracking duplicates if they are already executing this block
    if entries[-1]["message"] == target_task:
        print(f"Status: Already actively tracking '{target_task}'")
        return

    log_task(target_task)

def show_summary(target_date):
    """
    Generates a beautifully aligned dashboard view.
    It reads raw data strings, calculates true visual padding constraints, 
    and overlays high-contrast ANSI colors right before rendering.
    """
    file_path = get_file_path(target_date)
    if not os.path.exists(file_path):
        print(f"No time log found for {target_date}.")
        return

    entries = parse_log(file_path)
    if not entries:
        print(f"Log file for {target_date} is empty.")
        return

    display_rows, total_work_duration = calculate_daily_durations(target_date, entries)
    headers = ["ID", "Start", "End", "Duration", "Task"]
    
    # Pre-calculate padding bounds BEFORE applying ANSI color escape injection formatting codes
    col_widths = [len(h) for h in headers]
    for i, r in enumerate(display_rows):
        end_display = f"{r['end']} (current)" if r['is_active_current'] else r['end']
        col_widths[0] = max(col_widths[0], len(str(i + 1)))
        col_widths[1] = max(col_widths[1], len(r["start"]))
        col_widths[2] = max(col_widths[2], len(end_display))
        col_widths[3] = max(col_widths[3], len(r["duration"]))
        col_widths[4] = max(col_widths[4], len(r["task"]))
            
    human_date = get_ordinal_date(target_date)
    print(f"\n{CLR_TITLE}## Time Summary for {human_date} ({target_date}){CLR_RESET}\n")
    
    # Display Colorized Headers
    padded_headers = [f"{headers[idx]:<{col_widths[idx]}}" for idx in range(5)]
    print(f"{CLR_TEXT}|{CLR_RESET} " + f" {CLR_TEXT}|{CLR_RESET} ".join(f"{CLR_HEAD}{h}{CLR_RESET}" for h in padded_headers) + f" {CLR_TEXT}|{CLR_RESET}")
    print(f"{CLR_TEXT}|{CLR_RESET} " + f" {CLR_TEXT}|{CLR_RESET} ".join(f"{CLR_TEXT}{'-' * col_widths[idx]}{CLR_RESET}" for idx in range(5)) + f" {CLR_TEXT}|{CLR_RESET}")
    
    # Display Dynamic Rows
    for i, r in enumerate(display_rows):
        end_display = f"{r['end']} (current)" if r['is_active_current'] else r['end']
        padded_cells = [
            f"{str(i + 1):<{col_widths[0]}}",
            f"{r['start']:<{col_widths[1]}}",
            f"{end_display:<{col_widths[2]}}",
            f"{r['duration']:<{col_widths[3]}}",
            f"{r['task']:<{col_widths[4]}}"
        ]
        
        colored_cells = []
        for idx, cell_str in enumerate(padded_cells):
            if r['is_active_current']:
                # Bright green styling for current live entries
                colored_cells.append(f"{CLR_CMD}{cell_str}{CLR_RESET}" if idx in [2, 3] else f"{CLR_BOLD}{cell_str}{CLR_RESET}")
            elif r['is_break']:
                # Dim gray styling for structural break breaks
                colored_cells.append(f"{CLR_TEXT}{cell_str}{CLR_RESET}")
            else:
                colored_cells.append(cell_str)
                
        print(f"{CLR_TEXT}|{CLR_RESET} " + f" {CLR_TEXT}|{CLR_RESET} ".join(colored_cells) + f" {CLR_TEXT}|{CLR_RESET}")
    
    total_str = format_duration(total_work_duration) if total_work_duration.total_seconds() > 0 else "0m"
    print(f"{CLR_TEXT}└──{CLR_RESET} {CLR_HEAD}Total Logged Hours:{CLR_RESET} {CLR_CMD}{total_str}{CLR_RESET}\n")
    _warn_unclosed(target_date)

def show_weekly_summary(week_modifier=None):
    """
    Compiles an aggregated, multi-day timesheet grid. This function evaluates 
    relative lookbacks ('last'), shift counters ('2'), or explicit calendar anchor points.
    """
    today = datetime.now()
    base_monday = today - timedelta(days=today.weekday())
    
    # Parse lookback parameters to adjust the base target Monday
    if week_modifier:
        if week_modifier.lower() == "last":
            base_monday -= timedelta(weeks=1)
        elif week_modifier.isdigit():
            base_monday -= timedelta(weeks=int(week_modifier))
        else:
            try:
                target_dt = datetime.strptime(week_modifier, "%Y-%m-%d")
                base_monday = target_dt - timedelta(days=target_dt.weekday())
            except ValueError:
                print(f"{CLR_TEXT}Error: Invalid week modifier '{week_modifier}'. Use 'last', a number (e.g., '2'), or a date 'YYYY-MM-DD'.{CLR_RESET}")
                return
    
    weekly_grid = []
    weekly_breakdowns = {}
    grand_total_duration = timedelta(0)
    
    # Pull data sequentially from Monday (0) through Sunday (6)
    for i in range(7):
        day_dt = base_monday + timedelta(days=i)
        day_str = day_dt.strftime("%Y-%m-%d")
        day_name = day_dt.strftime("%A")
        
        file_path = get_file_path(day_str)
        entries = parse_log(file_path)
        
        if entries:
            rows, daily_total = calculate_daily_durations(day_str, entries)
            grand_total_duration += daily_total
            weekly_grid.append([day_name, day_str, format_duration(daily_total)])
            weekly_breakdowns[f"{day_name} ({day_str})"] = rows
        else:
            weekly_grid.append([day_name, day_str, "-"])

    # 1. Print the High-Level Timesheet Grid Matrix
    print(f"\n{CLR_TITLE}🗓️  Weekly Timesheet Matrix (Week of {base_monday.strftime('%Y-%m-%d')}){CLR_RESET}\n")
    headers = ["Day", "Date", "Total Hours"]
    widths = [10, 12, 12]
    
    padded_headers = [f"{headers[idx]:<{widths[idx]}}" for idx in range(3)]
    print(f"{CLR_TEXT}|{CLR_RESET} " + f" {CLR_TEXT}|{CLR_RESET} ".join(f"{CLR_HEAD}{h}{CLR_RESET}" for h in padded_headers) + f" {CLR_TEXT}|{CLR_RESET}")
    print(f"{CLR_TEXT}|{CLR_RESET} " + f" {CLR_TEXT}|{CLR_RESET} ".join(f"{CLR_TEXT}{'-' * widths[idx]}{CLR_RESET}" for idx in range(3)) + f" {CLR_TEXT}|{CLR_RESET}")
    
    for row in weekly_grid:
        color = CLR_RESET if row[2] != "-" else CLR_TEXT
        padded_cells = [f"{row[0]:<{widths[0]}}", f"{row[1]:<{widths[1]}}", f"{row[2]:<{widths[2]}}"]
        print(f"{CLR_TEXT}|{CLR_RESET} " + f" {CLR_TEXT}|{CLR_RESET} ".join(f"{color}{c}{CLR_RESET}" for c in padded_cells) + f" {CLR_TEXT}|{CLR_RESET}")
        
    grand_str = format_duration(grand_total_duration) if grand_total_duration.total_seconds() > 0 else "0m"
    print(f"{CLR_TEXT}└──{CLR_RESET} {CLR_HEAD}Grand Total Weekly Hours:{CLR_RESET} {CLR_CMD}{grand_str}{CLR_RESET}\n")

    # Any day here whose final entry never closed is under-reporting above.
    for row in weekly_grid:
        _warn_unclosed(row[1])
    
    # 2. Print an itemized task list, aggregated by task name to show total time per task
    if weekly_breakdowns:
        print(f"{CLR_TITLE}🔍 Itemized Task Notes Reference:{CLR_RESET}")
        for day_title, tasks in weekly_breakdowns.items():
            print(f"\n{CLR_HEAD}### {day_title}{CLR_RESET}")
            task_totals = {}
            task_order = []
            for t in tasks:
                if t['is_break']:
                    continue
                name = t['task']
                if name not in task_totals:
                    task_totals[name] = timedelta(0)
                    task_order.append(name)
                task_totals[name] += t['duration_td']
            for name in task_order:
                total_td = task_totals[name]
                total_str = format_duration(total_td) if total_td.total_seconds() > 0 else "-"
                print(f"  {CLR_TEXT}•{CLR_RESET} ({CLR_CMD}{total_str}{CLR_RESET}) → {name}")
        print()

def show_status():
    """Queries and echoes immediate tracking session performance metrics."""
    today_str = datetime.now().strftime("%Y-%m-%d")
    entries = parse_log(get_file_path(today_str))
    if not entries:
        print("Status: Not working on anything yet today.")
        return
    
    last_entry = entries[-1]
    if last_entry["message"].lower() in ["stop", "break", "end"]:
        print(f"Status: On a break / Stopped (since {last_entry['time']})")
    else:
        print(f"Current Task: {last_entry['message']}")

def sync_to_cloud():
    """Validates configuration parameters and syncs your vault directories via rclone."""
    print(f"{CLR_TITLE}🔄 Syncing logs to Google Drive...{CLR_RESET}")
    try:
        subprocess.Popen(["rclone", "--version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    except FileNotFoundError:
        print("Error: 'rclone' utility not found. Please install it first.")
        return

    cmd = ["rclone", "sync", LOG_BASE_DIR, "gdrive:LogTimeBackup", "-v"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            print(f"{CLR_CMD}✨ Backup successful! Your logs are secure in the cloud.{CLR_RESET}")
        else:
            print(f"❌ Sync failed. Rclone output:\n{result.stderr}")
    except Exception as e:
        print(f"❌ An error occurred during sync: {e}")

# ======================================================================
# JIRA INTEGRATION COMMANDS
# ======================================================================

def _jira_emit_json(payload):
    """Machine-readable output for the JottBar app. Never includes the token."""
    print(json.dumps(payload))


def _jira_ask(label, current, hint=None):
    """One setup prompt. Return keeps the current value; '-' clears it."""
    suffix = f" [{current}]" if current else (f" ({hint})" if hint else "")
    try:
        answer = input(f"  {label}{suffix}: ").strip()
    except (EOFError, KeyboardInterrupt):
        print("\nCancelled. Nothing was changed.")
        sys.exit(1)
    if answer == "-":
        return ""
    return answer if answer else current


def jira_setup(site=None, email=None, cloud_id=None, as_json=False):
    """
    Shows or sets the connection settings -- site, account email, and the
    cloud id that scoped tokens need.

    These used to be hand-edited into config.toml, which made connecting a
    two-tool job: a text editor for the account, then the CLI for the token.
    JottBar's Settings pane drives this with --json so the whole setup can
    happen in one place; the file stays perfectly editable by hand.
    """
    current = jira.get_connection()
    supplied = any(value is not None for value in (site, email, cloud_id))

    if not supplied:
        if as_json:
            _jira_emit_json({"ok": True, **current})
            return
        if not sys.stdin.isatty():
            _jira_print_connection(current)
            return
        print(f"{CLR_TITLE}Jira connection{CLR_RESET}")
        print(f"{CLR_TEXT}Press Return to keep a value, '-' to clear it.{CLR_RESET}")
        site = _jira_ask("Site URL", current["site"],
                         hint="https://yourcompany.atlassian.net")
        email = _jira_ask("Account email", current["email"],
                          hint="you@company.com")
        cloud_id = _jira_ask("Cloud id", current["cloud_id"],
                             hint="blank unless your token is scoped")

    try:
        saved = jira.save_connection(site=site, email=email, cloud_id=cloud_id)
    except jira.JiraError as e:
        if as_json:
            _jira_emit_json({"ok": False, "error": str(e), **current})
            return
        print(f"{CLR_TEXT}{e}{CLR_RESET}")
        sys.exit(1)

    if as_json:
        _jira_emit_json({"ok": True, **saved})
        return

    print(f"{CLR_CMD}✅ Saved to {CONFIG_FILE}.{CLR_RESET}")
    _jira_print_connection(saved)
    # The token is keyed by email in the Keychain, so a changed account
    # needs a fresh login even though the old token is still stored.
    if saved["configured"]:
        try:
            token = jira.get_token(saved["email"])
        except jira.JiraError:
            token = None
        if not token:
            print(f"{CLR_TEXT}Next: run 'jott jira login' to store the API token.{CLR_RESET}")


def _jira_print_connection(connection):
    print(f"  Site:      {CLR_BOLD}{connection['site'] or '— not set —'}{CLR_RESET}")
    print(f"  Email:     {CLR_BOLD}{connection['email'] or '— not set —'}{CLR_RESET}")
    print(f"  Cloud id:  {CLR_TEXT}{connection['cloud_id'] or 'none (classic token)'}{CLR_RESET}")


def jira_login(from_stdin=False):
    """
    Verifies an API token and stores it in the Keychain.

    Interactively the token is read with getpass so it is never echoed.
    With --stdin it is read from the pipe instead, which is how the JottBar
    Settings pane connects without duplicating any of this logic.
    """
    try:
        config = jira.get_config()
    except jira.JiraError as e:
        if from_stdin:
            _jira_emit_json({"ok": False, "error": str(e)})
            return
        print(f"{CLR_TEXT}{e}{CLR_RESET}")
        sys.exit(1)

    if from_stdin:
        token = sys.stdin.read().strip()
        if not token:
            _jira_emit_json({"ok": False, "error": "No token supplied."})
            return
        try:
            display_name = jira.verify(config, token)
            jira.store_token(config["email"], token)
        except jira.JiraError as e:
            _jira_emit_json({"ok": False, "error": str(e)})
            return
        _jira_emit_json({"ok": True, "display_name": display_name})
        return

    print(f"{CLR_TITLE}Connecting to {config['site']} as {config['email']}{CLR_RESET}")
    print(f"{CLR_TEXT}Create a token at https://id.atlassian.com/manage-profile/security/api-tokens{CLR_RESET}")
    if config.get("cloud_id"):
        print(f"{CLR_TEXT}Using scoped-token routing via cloud id {config['cloud_id']}.{CLR_RESET}")

    try:
        token = getpass.getpass("API token (input hidden): ").strip()
    except (EOFError, KeyboardInterrupt):
        print("\nCancelled.")
        sys.exit(1)

    if not token:
        print(f"{CLR_TEXT}No token entered. Nothing was saved.{CLR_RESET}")
        sys.exit(1)

    # A terminal in canonical mode caps a single input line at 1023 bytes and
    # discards anything longer, so a very long scoped token cannot be pasted
    # at a prompt at all. Point at the pipe instead of failing obscurely.
    if len(token) >= 1023:
        print(f"{CLR_TEXT}That token is {len(token)} characters, which your terminal "
              f"may have truncated at its 1023-byte line limit.{CLR_RESET}")
        print(f"{CLR_TEXT}If login fails, pipe it instead:{CLR_RESET}")
        print(f"  {CLR_CMD}printf %s \"$TOKEN\" | jott jira login --stdin{CLR_RESET}")

    try:
        display_name = jira.verify(config, token)
        jira.store_token(config["email"], token)
    except jira.JiraError as e:
        print(f"{CLR_TEXT}{e}{CLR_RESET}")
        sys.exit(1)

    print(f"{CLR_CMD}✅ Connected as {display_name}. Token saved to your Keychain.{CLR_RESET}")


def jira_logout():
    """Removes the stored token."""
    try:
        config = jira.get_config()
    except jira.JiraError as e:
        print(f"{CLR_TEXT}{e}{CLR_RESET}")
        sys.exit(1)
    jira.delete_token(config["email"])
    print(f"{CLR_CMD}Token removed from your Keychain.{CLR_RESET}")


def jira_status(as_json=False):
    """Reports configuration and connectivity without revealing the token."""
    try:
        config = jira.get_config()
    except jira.JiraError as e:
        if as_json:
            _jira_emit_json({"ok": False, "configured": False, "error": str(e)})
            return
        print(f"{CLR_TEXT}{e}{CLR_RESET}")
        sys.exit(1)

    if as_json:
        try:
            token = jira.get_token(config["email"])
        except jira.JiraError as e:
            _jira_emit_json({"ok": False, "configured": True, "error": str(e)})
            return
        payload = {
            "ok": True,
            "configured": True,
            "site": config["site"],
            "email": config["email"],
            "mode": "scoped" if config.get("cloud_id") else "classic",
            "jql": config["jql"],
            "token_stored": bool(token),
            "valid": False,
            "display_name": None,
            "error": None,
        }
        if token:
            try:
                payload["display_name"] = jira.verify(config, token)
                payload["valid"] = True
            except jira.JiraError as e:
                payload["error"] = str(e)
        _jira_emit_json(payload)
        return

    print(f"{CLR_TITLE}🔗 Jira Connection{CLR_RESET}")
    print(f"  Site:   {CLR_BOLD}{config['site']}{CLR_RESET}")
    print(f"  Email:  {CLR_BOLD}{config['email']}{CLR_RESET}")
    print(f"  Mode:   {CLR_BOLD}{'scoped token' if config.get('cloud_id') else 'classic token'}{CLR_RESET}")
    print(f"  JQL:    {CLR_TEXT}{config['jql']}{CLR_RESET}")

    try:
        token = jira.get_token(config["email"])
    except jira.JiraError as e:
        print(f"  Token:  {CLR_TEXT}{e}{CLR_RESET}")
        return
    if not token:
        print(f"  Token:  {CLR_TEXT}not stored — run 'jott jira login'{CLR_RESET}")
        return

    try:
        display_name = jira.verify(config, token)
        print(f"  Token:  {CLR_CMD}valid (authenticated as {display_name}){CLR_RESET}")
    except jira.JiraError as e:
        print(f"  Token:  {CLR_TEXT}{e}{CLR_RESET}")


def jira_jql(query=None, as_json=False, reset=False):
    """
    Shows or sets the JQL that drives the issue list.

    A new query is validated against Jira before it is saved -- a typo in a
    field name would otherwise show up much later as an empty autocomplete
    list with nothing to explain it.
    """
    # Showing the current query needs no credentials at all.
    if query is None and not reset:
        current = jira.get_jql()
        if as_json:
            _jira_emit_json({"ok": True, "jql": current, "is_default": jira.is_default_jql()})
            return
        print(f"{CLR_TITLE}Jira issue query{CLR_RESET}")
        print(f"  {CLR_BOLD}{current}{CLR_RESET}")
        if jira.is_default_jql():
            print(f"  {CLR_TEXT}(the default — set your own with: jott jira jql \"<query>\"){CLR_RESET}")
        return

    if reset:
        jira.reset_jql()
        if as_json:
            _jira_emit_json({"ok": True, "jql": jira.get_jql(), "is_default": True})
            return
        print(f"{CLR_CMD}✅ Restored the default query.{CLR_RESET}")
        print(f"  {CLR_TEXT}{jira.get_jql()}{CLR_RESET}")
        return

    try:
        config = jira.get_config()
        token = jira.get_token(config["email"])
        if not token:
            raise jira.JiraError("No API token stored. Run 'jott jira login'.")
        matched, exact = jira.validate_jql(config, token, query)
        jira.set_jql(query)
    except jira.JiraError as e:
        if as_json:
            _jira_emit_json({"ok": False, "error": str(e)})
            return
        print(f"{CLR_TEXT}{e}{CLR_RESET}")
        sys.exit(1)

    tally = f"{matched}" if exact else f"{matched}+"

    if as_json:
        _jira_emit_json({"ok": True, "jql": jira.get_jql(), "is_default": False,
                         "matched": matched, "matched_exact": exact})
        return

    print(f"{CLR_CMD}✅ Saved. {tally} issue(s) match.{CLR_RESET}")
    print(f"  {CLR_TEXT}{query}{CLR_RESET}")
    if matched == 0:
        # Jira accepts an unknown field name and returns nothing, so an
        # empty result is worth calling out rather than reading as success.
        print(f"{CLR_TEXT}Nothing matched — check field names and values; "
              f"Jira accepts an unknown field without complaint.{CLR_RESET}")


def jira_issues(as_json=False, force_refresh=False):
    """
    Lists assigned issues, served from a short-lived cache so autocomplete
    stays instant and keeps working while offline.
    """
    cache = jira.read_cache()
    age = jira.cache_age(cache)
    fresh = age is not None and age < jira.CACHE_TTL_SECONDS
    limit = jira.get_issue_limit()

    if fresh and not force_refresh:
        issues, stale, error = cache["issues"], False, None
        truncated = bool(cache.get("truncated"))
    else:
        try:
            config = jira.get_config()
            token = jira.get_token(config["email"])
            if not token:
                raise jira.JiraError("No API token stored. Run 'jott jira login'.")
            issues, truncated = jira.fetch_issues(config, token, limit=limit)
            jira.write_cache(issues, truncated=truncated, limit=limit)
            stale, error = False, None
        except jira.JiraError as e:
            # Fall back to whatever is cached rather than losing autocomplete
            # entirely because the network blipped.
            if cache:
                issues, stale, error = cache["issues"], True, str(e)
                truncated = bool(cache.get("truncated"))
            else:
                if as_json:
                    _jira_emit_json({"ok": False, "issues": [], "error": str(e)})
                    return
                print(f"{CLR_TEXT}{e}{CLR_RESET}")
                sys.exit(1)

    if as_json:
        _jira_emit_json({
            "ok": True,
            "issues": issues,
            "stale": stale,
            "error": error,
            "truncated": truncated,
            "limit": limit,
            "fetched_at": (cache or {}).get("fetched_at"),
        })
        return

    if not issues:
        print(f"{CLR_TEXT}No issues matched your JQL.{CLR_RESET}")
        return

    print(f"\n{CLR_TITLE}🎫 Issues Assigned To You{CLR_RESET}")
    if stale:
        print(f"{CLR_TEXT}(showing cached results — {error}){CLR_RESET}")
    width = max(len(i["key"]) for i in issues)
    for issue in issues:
        status = f" {CLR_TEXT}[{issue['status']}]{CLR_RESET}" if issue["status"] else ""
        print(f"  {CLR_CMD}{issue['key']:<{width}}{CLR_RESET}  {issue['summary']}{status}")

    if truncated:
        # Never drop the tail silently: an issue missing from autocomplete
        # because it sorted past the limit is indistinguishable from a broken
        # query. Printed after the list so it is the last thing on screen
        # rather than scrolled away above a few hundred rows.
        print(f"\n{CLR_HEAD}⚠ Showing the first {len(issues)} issues — your query matches more.{CLR_RESET}")
        print(f"{CLR_TEXT}  Narrow the JQL, or raise jira_issue_limit in {CONFIG_FILE}.{CLR_RESET}")
    print()


def _warn_unclosed(date_str):
    """
    Flags a past day whose final entry never got closed.

    That entry has no following timestamp to measure against, so its time is
    not counted anywhere. Warning is the whole point: the failure is
    otherwise completely silent.
    """
    unclosed = is_unclosed(date_str)
    if not unclosed:
        return
    print(f"{CLR_HEAD}⚠  {date_str} was never closed out.{CLR_RESET}")
    print(f"   '{unclosed['task']}' has been open since {unclosed['since']} and is NOT counted.")
    print(f"   Fix it with: {CLR_CMD}jott edit {date_str}{CLR_RESET}  (add a 'stop' line at the real end time)")


def find_entries(query, limit=50, as_json=False):
    """
    Searches every ledger on disk for entries whose text matches, newest
    first, with the time each one accounted for.
    """
    needle = query.lower()
    matches = []

    for date_str in reversed(list(iter_log_dates())):
        entries = parse_log(get_file_path(date_str))
        if not entries:
            continue
        rows, _ = calculate_daily_durations(date_str, entries)
        for row in rows:
            if needle in row["task"].lower():
                matches.append({
                    "date": date_str,
                    "start": row["start"],
                    "end": row["end"],
                    "duration": row["duration"],
                    "seconds": int(row["duration_td"].total_seconds()),
                    "task": row["task"],
                })
                if len(matches) >= limit:
                    break
        if len(matches) >= limit:
            break

    total_seconds = sum(m["seconds"] for m in matches)

    if as_json:
        _jira_emit_json({"ok": True, "query": query, "matches": matches,
                         "total_seconds": total_seconds})
        return

    if not matches:
        print(f"{CLR_TEXT}No entries matching '{query}'.{CLR_RESET}")
        return

    print(f"\n{CLR_TITLE}🔍 Entries matching '{query}'{CLR_RESET}\n")
    task_width = max(len(m["task"]) for m in matches)
    for m in matches:
        print(f"  {CLR_TEXT}{m['date']}{CLR_RESET}  {CLR_BOLD}{m['start'][:5]}{CLR_RESET}  "
              f"{CLR_CMD}{m['duration']:>7}{CLR_RESET}  {m['task']:<{task_width}}")

    total = format_duration(timedelta(seconds=total_seconds))
    noun = "entry" if len(matches) == 1 else "entries"
    print(f"\n{CLR_TEXT}└──{CLR_RESET} {CLR_HEAD}{len(matches)} {noun}, {CLR_RESET}{CLR_CMD}{total}{CLR_RESET} total\n")


def show_help():
    """Outputs structured usage documentation and your colorized ASCII branding logo."""
    # Prefixing with 'fr' flags this block as both a Raw String and a formatted literal.
    # This instructs Python's compiler to skip standard escape rules, completely 
    # eliminating any potential backslash 'SyntaxWarning' exceptions inside the ASCII logo.
    print(fr"""{CLR_TITLE}    _         _   _   
   (_)  ___  | |_| |_ 
   | | / _ \ | __| __|
   | || (_) || |_| |_ 
  _/ | \___/  \__|\__| 
 |__/                   

======================================================================
  🕒 JOTT CLI — Simple Terminal Time Tracker
======================================================================{CLR_RESET}
CONFIG FILE:
  {CLR_BOLD}{CONFIG_FILE}{CLR_RESET}
ACTIVE LOG OUTPUT TARGET:
  {CLR_BOLD}{LOG_BASE_DIR}{CLR_RESET}

{CLR_HEAD}USAGE:{CLR_RESET}
  {CLR_CMD}jott "your task description"{CLR_RESET}    Starts tracking a new task immediately.
  {CLR_CMD}jott [command]{CLR_RESET}                  Executes structural logging commands.

{CLR_HEAD}COMMANDS:{CLR_RESET}
  {CLR_CMD}backlog [mins] "[task]"{CLR_RESET}     Logs a task that started a given number of minutes ago.
  {CLR_CMD}continue{CLR_RESET}                    Resumes your immediate previous task prior to a break.
  {CLR_CMD}continue [id]{CLR_RESET}               Resumes a specific historical task via its row ID number.
  {CLR_CMD}edit{CLR_RESET}                        Opens today's log in Neovim and compiles it on exit.
  {CLR_CMD}edit yesterday{CLR_RESET}              Opens yesterday's log in Neovim.
  {CLR_CMD}edit YYYY-MM-DD{CLR_RESET}             Opens any explicit targeted historical log in Neovim.
  {CLR_CMD}rewrite [date]{CLR_RESET}              Replaces a day's entries with 'HH:MM:SS | task' lines from stdin.
  {CLR_CMD}status{CLR_RESET}                      Displays active task & runtime.
  {CLR_CMD}view{CLR_RESET}                        Streams today's pre-calculated summary from disk.
  {CLR_CMD}view yesterday{CLR_RESET}              Streams yesterday's summary from disk.
  {CLR_CMD}view week{CLR_RESET}                   Renders the current week's timesheet matrix grid.
  {CLR_CMD}view week last{CLR_RESET}              Renders the previous week's timesheet matrix grid.
  {CLR_CMD}view week [num]{CLR_RESET}              Renders the matrix grid from [num] weeks ago.
  {CLR_CMD}view week [date]{CLR_RESET}             Renders the matrix grid for the week containing [date].
  {CLR_CMD}week [modifier]{CLR_RESET}              Shorthand wrapper for 'view week [modifier]'.
  {CLR_CMD}find "[text]"{CLR_RESET}                Searches every ledger for matching entries.
  {CLR_CMD}find "[text]" --limit 20{CLR_RESET}    Caps how many matches are shown (default 50).
  {CLR_CMD}sync{CLR_RESET}                        Backs up archive directory structure via rclone.

{CLR_HEAD}JIRA:{CLR_RESET}
  {CLR_CMD}jira setup{CLR_RESET}                  Sets your Jira site, account email and cloud id.
  {CLR_CMD}jira login{CLR_RESET}                  Stores your Jira API token in the macOS Keychain.
  {CLR_CMD}jira status{CLR_RESET}                 Shows connection settings and verifies the token.
  {CLR_CMD}jira issues{CLR_RESET}                 Lists the issues currently assigned to you.
  {CLR_CMD}jira issues --refresh{CLR_RESET}       Bypasses the 15 minute cache.
  {CLR_CMD}jira jql{CLR_RESET}                    Shows the query that picks which issues appear.
  {CLR_CMD}jira jql "<query>"{CLR_RESET}          Sets your own JQL, validated before saving.
  {CLR_CMD}jira jql --reset{CLR_RESET}            Restores the default query.
  {CLR_CMD}jira logout{CLR_RESET}                 Removes the stored token.
  {CLR_CMD}help{CLR_RESET}                        Presents this guide.

{CLR_HEAD}SPECIAL KEYWORDS:{CLR_RESET}
  Using {CLR_CMD}stop{CLR_RESET}, {CLR_CMD}break{CLR_RESET}, or {CLR_CMD}end{CLR_RESET} marks a pause and stops billing time to metrics.
""")
