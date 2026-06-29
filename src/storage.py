import os
import sys
from datetime import datetime, timedelta
from .config import LOG_BASE_DIR
from .helpers import format_duration, get_ordinal_date

def get_file_path(date_str=None):
    """
    Determines and routes file system paths using structured groupings
    to keep historical records manageable: [LOG_BASE_DIR]/YYYY/MM/YYYY-MM-DD.md
    """
    if not date_str:
        date_str = datetime.now().strftime("%Y-%m-%d")
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d")
        return os.path.join(LOG_BASE_DIR, dt.strftime("%Y"), dt.strftime("%m"), f"{date_str}.md")
    except ValueError:
        print(f"Error: Internal date parsing failure for '{date_str}'.")
        sys.exit(1)

def parse_log(file_path):
    """
    Reads the raw data lines from a file. This function isolates 
    user entries (`- HH:MM:SS | task`) while completely ignoring 
    pre-rendered Markdown summary report grids.
    """
    if not os.path.exists(file_path):
        return []
    
    entries = []
    with open(file_path, "r") as f:
        for line in f:
            # Only match the explicit prefix signature used for user logs
            if line.startswith("- "):
                parts = line.strip("- \n").split(" | ", 1)
                if len(parts) == 2:
                    entries.append({"time": parts[0], "message": parts[1]})
                    
    # Maintain strict chronological sequencing across tracking operations
    entries.sort(key=lambda x: x["time"])
    return entries

def calculate_daily_durations(target_date, entries):
    """
    Calculates operational timeline durations. It compares subsequent entry 
    timestamps, isolates pause/stop modifiers, and tracks active runtime.
    """
    rows = []
    total_work_duration = timedelta(0)
    is_today = (target_date == datetime.now().strftime("%Y-%m-%d"))
    
    for i in range(len(entries)):
        start_dt = datetime.strptime(entries[i]["time"], "%H:%M:%S")
        task = entries[i]["message"]
        is_break = task.lower() in ["stop", "break", "end"]
        
        # Determine tracking end times by peeking at the next row's timestamp
        if i + 1 < len(entries):
            end_dt = datetime.strptime(entries[i+1]["time"], "%H:%M:%S")
            end_str = entries[i+1]["time"]
            duration = end_dt - start_dt
        else:
            # Active Row Evaluation logic for incomplete lines
            if is_break:
                end_str, duration = "-", timedelta(0)
            elif is_today:
                # Live Delta calculating mechanism updates your current session active metrics
                end_dt = datetime.strptime(datetime.now().strftime("%H:%M:%S"), "%H:%M:%S")
                end_str = f"{end_dt.strftime('%H:%M:%S')}"
                duration = end_dt - start_dt
            else:
                end_str, duration = "-", timedelta(0)
        
        # Accumulate client billing logs only if the item is an active milestone
        if not is_break:
            total_work_duration += duration
            
        dur_str = format_duration(duration) if duration.total_seconds() > 0 else "-"
        rows.append({
            "start": entries[i]["time"],
            "end": end_str,
            "duration": dur_str,
            "duration_td": duration,
            "task": task,
            "is_break": is_break,
            "is_active_current": is_today and i == len(entries) - 1 and not is_break
        })
    return rows, total_work_duration

def generate_and_save_report(target_date):
    """
    The Write-Cached Core Engine. Whenever data is logged, this function 
    re-computes structural metrics and cleanly appends an authentic Markdown 
    table back to the file. This keeps the file self-contained and accurate.
    """
    file_path = get_file_path(target_date)
    entries = parse_log(file_path)
    if not entries:
        return

    # Extract clean baseline numbers
    rows, total_work_duration = calculate_daily_durations(target_date, entries)
    headers = ["ID", "Start", "End", "Duration", "Task"]
    
    # Calculate text column padding based on visible character string length
    col_widths = [len(h) for h in headers]
    for i, r in enumerate(rows):
        col_widths[0] = max(col_widths[0], len(str(i + 1)))
        col_widths[1] = max(col_widths[1], len(r["start"]))
        col_widths[2] = max(col_widths[2], len(r["end"]))
        col_widths[3] = max(col_widths[3], len(r["duration"]))
        col_widths[4] = max(col_widths[4], len(r["task"]))
            
    human_date = get_ordinal_date(target_date)
    
    # 1. Re-render baseline file system log append structures
    lines = [f"# Time Log: {target_date}\n"]
    for entry in entries:
        lines.append(f"- {entry['time']} | {entry['message']}")
    
    # 2. Append perfectly aligned Markdown structure summaries
    lines.append(f"\n## Summary Report")
    lines.append(f"Date: {human_date}\n")
    
    padded_headers = [f"{headers[idx]:<{col_widths[idx]}}" for idx in range(5)]
    lines.append("| " + " | ".join(padded_headers) + " |")
    lines.append("| " + " | ".join(f"{'-' * col_widths[idx]}" for idx in range(5)) + " |")
    
    for i, r in enumerate(rows):
        line_cells = [
            f"{str(i + 1):<{col_widths[0]}}",
            f"{r['start']:<{col_widths[1]}}",
            f"{r['end']:<{col_widths[2]}}",
            f"{r['duration']:<{col_widths[3]}}",
            f"{r['task']:<{col_widths[4]}}"
        ]
        lines.append("| " + " | ".join(line_cells) + " |")
        
    total_str = format_duration(total_work_duration) if total_work_duration.total_seconds() > 0 else "0m"
    lines.append(f"\n└── Total Logged Hours: {total_str}")
    
    # Overwrite the file to save the newly compiled state cleanly
    with open(file_path, "w") as f:
        f.write("\n".join(lines) + "\n")
