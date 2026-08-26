import os

# ======================================================================
# CONFIGURATION PLATFORM CONSTANTS (XDG BASE DESIGN)
# ======================================================================
# Maps explicitly to modern Unix/macOS environment specification directory standards.
CONFIG_DIR = os.path.expanduser("~/.config/jott")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.toml")
DEFAULT_LOG_DIR = os.path.expanduser("~/.jott")

def load_settings():
    """
    Parses every key/value pair out of config.toml into a plain dict.
    Same deliberately light token scan as before -- no external Pip
    dependencies -- just generalised beyond a single key so that the
    Jira integration can share the file.
    """
    settings = {}
    try:
        with open(CONFIG_FILE, "r") as f:
            for line in f:
                clean_line = line.strip()
                if not clean_line or clean_line.startswith("#"):
                    continue
                if "=" in clean_line:
                    key, val = clean_line.split("=", 1)
                    settings[key.strip()] = val.strip().strip('"').strip("'")
    except Exception:
        pass
    return settings


def get_setting(key, default=None):
    """Reads a single config value on demand, so edits apply without a relaunch."""
    value = load_settings().get(key)
    return value if value not in (None, "") else default


def load_configuration():
    """
    Resolves the targeted output directory for storing your log vaults.
    To maximize pipeline reliability in Homebrew distribution environments,
    this custom light parser evaluates basic TOML tokens natively without 
    relying on heavy external Pip dependencies.
    """
    # Self-Healing Layer: Initialize directory trees and default settings if missing
    if not os.path.exists(CONFIG_FILE):
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            with open(CONFIG_FILE, "w") as f:
                f.write("# 🕒 Jott CLI Configuration File\n")
                f.write("# You can change where your markdown log archives are saved below:\n\n")
                f.write(f'log_dir = "{DEFAULT_LOG_DIR}"\n')
                f.write("\n# --- Jira (optional) ---------------------------------------\n")
                f.write("# Run 'jott jira login' after filling these in.\n")
                f.write("# The API token is NOT stored here -- it goes in your Keychain.\n")
                f.write('# jira_site = "https://yourcompany.atlassian.net"\n')
                f.write('# jira_email = "you@company.com"\n')
                f.write('# jira_cloud_id = ""   # only for scoped API tokens\n')
            return DEFAULT_LOG_DIR
        except Exception:
            return DEFAULT_LOG_DIR

    resolved_path = DEFAULT_LOG_DIR
    try:
        with open(CONFIG_FILE, "r") as f:
            for line in f:
                clean_line = line.strip()
                # Bypass structural whitespace padding and user review comment rows
                if not clean_line or clean_line.startswith("#"):
                    continue
                if "=" in clean_line:
                    key, val = clean_line.split("=", 1)
                    if key.strip() == "log_dir":
                        # Strip formatting boundary markers and handle relative ~ paths
                        resolved_path = os.path.expanduser(val.strip().strip('"').strip("'"))
    except Exception:
        pass # Fallback cleanly to default home pathing on file system read exceptions
    
    return resolved_path

# Export global data path variables across active engine submodules
LOG_BASE_DIR = load_configuration()

# ======================================================================
# HIGH-CONTRAST ANSI TERMINAL COLOR PALETTE
# ======================================================================
# Applied on-the-fly dynamically right before interface rendering.
# This ensures that on-disk files remain pristine, raw Markdown.
CLR_TITLE = "\033[1;36m"  # Bold Cyan (Section Titles)
CLR_HEAD  = "\033[1;33m"  # Bold Yellow (Table Headers)
CLR_CMD   = "\033[1;32m"  # Bold Green (Highlights and Durations)
CLR_TEXT  = "\033[0;90m"  # Dim Gray (Borders and Structural Formatting)
CLR_RESET = "\033[0m"     # System Color Override Reset
CLR_BOLD  = "\033[1m"      # Pure Bold White (Active Tasks)
