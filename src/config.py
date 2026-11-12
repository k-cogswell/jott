import os

# ======================================================================
# CONFIGURATION PLATFORM CONSTANTS (XDG BASE DESIGN)
# ======================================================================
# Maps explicitly to modern Unix/macOS environment specification directory standards.
CONFIG_DIR = os.path.expanduser("~/.config/jott")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.toml")
DEFAULT_LOG_DIR = os.path.expanduser("~/.jott")

def _unquote(value):
    """
    Strips one MATCHED pair of surrounding quotes.

    The old .strip('"').strip("'") removed every quote at either end, which
    mangled any value containing its own quotes -- and JQL is full of them
    ("project = \"Sky Alyne\""). Only a balanced outer pair is removed now.
    """
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    return value


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
                    settings[key.strip()] = _unquote(val.strip())
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
                f.write("# Easiest path: 'jott jira setup', or JottBar's Settings pane.\n")
                f.write("# Fill these in by hand if you prefer, then 'jott jira login'.\n")
                f.write("# The API token is NOT stored here -- it goes in your Keychain.\n")
                f.write('# jira_site = "https://yourcompany.atlassian.net"\n')
                f.write('# jira_email = "you@company.com"\n')
                f.write('# jira_cloud_id = ""   # only for scoped API tokens\n')
                f.write("# Which issues appear in the prompt. Omit for assigned-and-open.\n")
                f.write("# Set it with 'jott jira jql \"<query>\"' so it is checked first.\n")
                f.write('# jira_jql = "assignee = currentUser() AND statusCategory != Done"\n')
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


# ======================================================================
# WRITING SETTINGS
# ======================================================================
# The app and 'jott jira jql' both need to edit config.toml in place. The
# file is hand-maintained and full of comments, so rewrite only the one
# line that changes and leave everything else alone.

def _quote(value):
    """
    Wraps a value in whichever quote style it does not itself contain.

    Paired with _unquote this round-trips any value using one quote style.
    A value containing BOTH cannot be represented by this parser, so say so
    rather than writing a line that would read back wrong.
    """
    if "\n" in value or "\r" in value:
        raise ValueError("A config value cannot contain a line break.")
    if '"' not in value:
        return f'"{value}"'
    if "'" not in value:
        return f"'{value}'"
    raise ValueError(
        "A config value cannot contain both single and double quotes. "
        "Rewrite it using only one style."
    )


def set_setting(key, value):
    """Sets one key, replacing its existing active line or appending one."""
    quoted = _quote(value)
    os.makedirs(CONFIG_DIR, exist_ok=True)

    try:
        with open(CONFIG_FILE, "r") as f:
            lines = f.readlines()
    except FileNotFoundError:
        lines = []

    replaced = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("#") or "=" not in stripped:
            continue
        if stripped.split("=", 1)[0].strip() == key:
            lines[i] = f"{key} = {quoted}\n"
            replaced = True
            break

    if not replaced:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"{key} = {quoted}\n")

    _write_lines(lines)


def unset_setting(key):
    """Removes a key's active line, restoring whatever default applies."""
    try:
        with open(CONFIG_FILE, "r") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return

    kept = []
    for line in lines:
        stripped = line.strip()
        if (not stripped.startswith("#") and "=" in stripped
                and stripped.split("=", 1)[0].strip() == key):
            continue
        kept.append(line)
    _write_lines(kept)


def _write_lines(lines):
    """
    Writes to a temporary file in the same directory, then renames. A
    half-written config.toml would take the log directory down with it,
    not just the Jira settings.
    """
    temp_path = CONFIG_FILE + ".tmp"
    with open(temp_path, "w") as f:
        f.writelines(lines)
    os.replace(temp_path, CONFIG_FILE)
