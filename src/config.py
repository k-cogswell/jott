import os

CONFIG_DIR = os.path.expanduser("~/.config/jott")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.toml")
DEFAULT_LOG_DIR = os.path.expanduser("~/.jott")

def load_configuration():
    """Loads the log directory from config.toml, creating defaults if missing."""
    if not os.path.exists(CONFIG_FILE):
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            with open(CONFIG_FILE, "w") as f:
                f.write("# 🕒 Jott CLI Configuration File\n")
                f.write("# You can change where your markdown log archives are saved below:\n\n")
                f.write(f'log_dir = "{DEFAULT_LOG_DIR}"\n')
            return DEFAULT_LOG_DIR
        except Exception:
            return DEFAULT_LOG_DIR

    resolved_path = DEFAULT_LOG_DIR
    try:
        with open(CONFIG_FILE, "r") as f:
            for line in f:
                clean_line = line.strip()
                if not clean_line or clean_line.startswith("#"):
                    continue
                if "=" in clean_line:
                    key, val = clean_line.split("=", 1)
                    if key.strip() == "log_dir":
                        resolved_path = os.path.expanduser(val.strip().strip('"').strip("'"))
    except Exception:
        pass
    
    return resolved_path

LOG_BASE_DIR = load_configuration()

# ANSI Color Themes
CLR_TITLE = "\033[1;36m"  # Bold Cyan
CLR_HEAD  = "\033[1;33m"  # Bold Yellow
CLR_CMD   = "\033[1;32m"  # Bold Green
CLR_TEXT  = "\033[0;90m"  # Muted Dark Gray / Dimmed
CLR_RESET = "\033[0m"     # Reset
CLR_BOLD  = "\033[1m"      # Pure Bold White