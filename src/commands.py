import os
import subprocess
from datetime import datetime, timedelta
from .config import LOG_BASE_DIR, CONFIG_FILE, CLR_TITLE, CLR_HEAD, CLR_CMD, CLR_TEXT, CLR_RESET, CLR_BOLD
from .helpers import format_duration, get_ordinal_date
from .storage import get_file_path, parse_log, calculate_daily_durations, generate_and_save_report

def log_task(message, custom_dt=None):
    target_dt = custom_dt if custom_dt else datetime.now()
    date_str = target_dt.strftime("%Y-%m-%d")
    time_str = target_dt.strftime("%H:%M:%S")
    file_path = get_file_path(date_str)
    
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    with open(file_path, "a") as f:
        f.write(f"- {time_str} | {message}\n")
        
    generate_and_save_report(date_str)
    backdate_msg = f" (backdated to {date_str})" if custom_dt else ""
    print(f"Recorded: [{time_str}]{backdate_msg} {message}")

def edit_ledger(target_date):
    """Launches Neovim to edit the target file, then automatically recompiles tables on save."""
    file_path = get_file_path(target_date)
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    
    # Initialize basic schema header if file does not exist yet
    if not os.path.exists(file_path):
        with open(file_path, "w") as f:
            f.write(f"# Time Log: {target_date}\n\n")

    print(f"{CLR_TITLE}📝 Opening ledger for {target_date} in Neovim...{CLR_RESET}")
    try:
        # Launch Neovim inside interactive shell context block
        subprocess.run(["nvim", file_path], check=True)
        
        # post-edit compilation catch
        generate_and_save_report(target_date)
        print(f"{CLR_CMD}✨ Save verified. Report table and hours compiled successfully for {target_date}.{CLR_RESET}")
    except FileNotFoundError:
        print(f"{CLR_TEXT}Error: 'nvim' binary executable was not found in your system path environment.{CLR_RESET}")
    except Exception as e:
        print(f"{CLR_TEXT}An error occurred executing your editor context: {e}{CLR_RESET}")

def continue_previous_task(target_id=None):
    today_str = datetime.now().strftime("%Y-%m-%d")
    entries = parse_log(get_file_path(today_str))
    
    if not entries:
        print(f"{CLR_TEXT}Error: No tasks logged yet today to continue.{CLR_RESET}")
        return

    target_task = None
    if target_id is not None:
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
        for entry in reversed(entries):
            if entry["message"].lower() not in ["stop", "break", "end"]:
                target_task = entry["message"]
                break

    if not target_task:
        print(f"{CLR_TEXT}Error: No valid work blocks found to continue from today.{CLR_RESET}")
        return

    if entries[-1]["message"] == target_task:
        print(f"Status: Already actively tracking '{target_task}'")
        return

    log_task(target_task)

def show_summary(target_date):
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
    
    padded_headers = [f"{headers[idx]:<{col_widths[idx]}}" for idx in range(5)]
    print(f"{CLR_TEXT}|{CLR_RESET} " + f" {CLR_TEXT}|{CLR_RESET} ".join(f"{CLR_HEAD}{h}{CLR_RESET}" for h in padded_headers) + f" {CLR_TEXT}|{CLR_RESET}")
    print(f"{CLR_TEXT}|{CLR_RESET} " + f" {CLR_TEXT}|{CLR_RESET} ".join(f"{CLR_TEXT}{'-' * col_widths[idx]}{CLR_RESET}" for idx in range(5)) + f" {CLR_TEXT}|{CLR_RESET}")
    
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
                colored_cells.append(f"{CLR_CMD}{cell_str}{CLR_RESET}" if idx in [2, 3] else f"{CLR_BOLD}{cell_str}{CLR_RESET}")
            elif r['is_break']:
                colored_cells.append(f"{CLR_TEXT}{cell_str}{CLR_RESET}")
            else:
                colored_cells.append(cell_str)
                
        print(f"{CLR_TEXT}|{CLR_RESET} " + f" {CLR_TEXT}|{CLR_RESET} ".join(colored_cells) + f" {CLR_TEXT}|{CLR_RESET}")
    
    total_str = format_duration(total_work_duration) if total_work_duration.total_seconds() > 0 else "0m"
    print(f"{CLR_TEXT}└──{CLR_RESET} {CLR_HEAD}Total Logged Hours:{CLR_RESET} {CLR_CMD}{total_str}{CLR_RESET}\n")

def show_weekly_summary():
    today = datetime.now()
    monday = today - timedelta(days=today.weekday())
    
    weekly_grid = []
    weekly_breakdowns = {}
    grand_total_duration = timedelta(0)
    
    for i in range(7):
        day_dt = monday + timedelta(days=i)
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

    print(f"\n{CLR_TITLE}🗓️  Weekly Timesheet Matrix (Week of {monday.strftime('%Y-%m-%d')}){CLR_RESET}\n")
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
    
    if weekly_breakdowns:
        print(f"{CLR_TITLE}🔍 Itemized Task Notes Reference:{CLR_RESET}")
        for day_title, tasks in weekly_breakdowns.items():
            print(f"\n{CLR_HEAD}### {day_title}{CLR_RESET}")
            for t in tasks:
                if t['is_break']:
                    continue
                end_lbl = f"{t['end']} (current)" if t['is_active_current'] else t['end']
                print(f"  {CLR_TEXT}•{CLR_RESET} [{t['start']} - {end_lbl}] ({CLR_CMD}{t['duration']}{CLR_RESET}) → {t['task']}")
        print()

def show_status():
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

def show_help():
    print(f"""
{CLR_TITLE}======================================================================
      _       _   _ 
     (_) ___ | |_| |_ 
     | |/ _ \| __| __|
     | | (_) | |_| |_ 
    _/ |\___/ \__|\__|
   |__/

  A Simple Terminal Time Tracker
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
  {CLR_CMD}status{CLR_RESET}                      Displays active task & runtime.
  {CLR_CMD}view{CLR_RESET}                        Streams today's pre-calculated summary from disk.
  {CLR_CMD}view yesterday{CLR_RESET}              Streams yesterday's summary from disk.
  {CLR_CMD}view week{CLR_RESET}                   Renders the 7-day high-level timesheet grid.
  {CLR_CMD}week{CLR_RESET}                        Shorthand wrapper for 'view week'.
  {CLR_CMD}sync{CLR_RESET}                        Backs up archive directory structure via rclone.
  {CLR_CMD}help{CLR_RESET}                        Presents this guide.

{CLR_HEAD}SPECIAL KEYWORDS:{CLR_RESET}
  Using {CLR_CMD}stop{CLR_RESET}, {CLR_CMD}break{CLR_RESET}, or {CLR_CMD}end{CLR_RESET} marks a pause and stops billing time to metrics.
""")
