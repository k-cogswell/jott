import sys
from datetime import datetime, timedelta

def format_duration(td):
    hours, remainder = divmod(int(td.total_seconds()), 3600)
    minutes, _ = divmod(remainder, 60)
    if hours > 0:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"

def get_ordinal_date(date_str):
    dt_obj = datetime.strptime(date_str, "%Y-%m-%d")
    day = dt_obj.day
    suffix = "th" if 11 <= day <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(day % 10, "th")
    return dt_obj.strftime(f"%A, %B {day}{suffix}, %Y")

def resolve_date(arg):
    if arg == "today":
        return datetime.now().strftime("%Y-%m-%d")
    elif arg == "yesterday":
        return (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
    else:
        try:
            datetime.strptime(arg, "%Y-%m-%d")
            return arg
        except ValueError:
            print(f"Error: Invalid date format '{arg}'. Use 'yesterday' or 'YYYY-MM-DD'.")
            sys.exit(1)