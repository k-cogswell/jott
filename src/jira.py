"""
Jira Cloud integration for Jott.

Deliberately stdlib-only (urllib, base64, json, subprocess) to preserve the
CLI's zero-dependency property -- the same reason the TOML parser in
config.py is hand-rolled.

Auth notes:
  * Jira CLOUD uses HTTP Basic with base64(email:api_token). It does NOT
    use Bearer PATs -- those are Jira Server/Data Center.
  * Classic (unscoped) tokens talk to https://<site>.atlassian.net directly.
  * Scoped tokens must go through https://api.atlassian.com/ex/jira/<cloud_id>.
    We pick the base URL based on whether jira_cloud_id is configured.

The token is never stored in config.toml -- it lives in the macOS Keychain,
and is never echoed or logged.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from .config import get_setting, set_setting, unset_setting, CONFIG_FILE, CLR_TITLE, CLR_HEAD, CLR_CMD, CLR_TEXT, CLR_RESET, CLR_BOLD

KEYCHAIN_SERVICE = "jott-jira"
CACHE_DIR = os.path.expanduser("~/.cache/jott")
CACHE_FILE = os.path.join(CACHE_DIR, "jira-issues.json")
CACHE_TTL_SECONDS = 900  # 15 minutes
REQUEST_TIMEOUT = 15

DEFAULT_JQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"

# Jira caps a single page of /search/jql at 100 regardless of maxResults.
PAGE_SIZE = 100
# How many issues to pull in total. Five pages is generous for autocomplete
# and still bounded; override with jira_issue_limit in config.toml.
DEFAULT_ISSUE_LIMIT = 500


class JiraError(Exception):
    """Carries a message already phrased for the user."""


# ======================================================================
# CONFIGURATION & CREDENTIALS
# ======================================================================

def get_config():
    """Reads Jira settings, raising with actionable guidance when unset."""
    site = get_setting("jira_site")
    email = get_setting("jira_email")
    if not site or not email:
        raise JiraError(
            "Jira is not configured yet.\n"
            "  Run: jott jira setup\n"
            f"  (or add jira_site and jira_email to {CONFIG_FILE} by hand)\n"
            "  Then run: jott jira login"
        )
    return {
        "site": site.rstrip("/"),
        "email": email,
        "cloud_id": get_setting("jira_cloud_id"),
        "jql": get_jql(),
    }


# ----------------------------------------------------------------------
# CONNECTION SETTINGS
# ----------------------------------------------------------------------
# get_config() deliberately refuses to hand back a half-configured account,
# which is right for anything that then talks to Jira. Setting the account
# up needs the opposite: whatever is there so far, so a form -- in the
# terminal or in JottBar's Settings pane -- can show it and complete it.
# These are the only writers of the jira_site/jira_email/jira_cloud_id keys,
# so config.toml keeps exactly one writer and its comments survive editing.

def get_connection():
    """The raw connection settings, complete or not."""
    site = (get_setting("jira_site") or "").rstrip("/")
    email = get_setting("jira_email") or ""
    return {
        "site": site,
        "email": email,
        "cloud_id": get_setting("jira_cloud_id") or "",
        "configured": bool(site and email),
    }


def normalize_site(raw):
    """
    Accepts what a person would actually paste and returns an origin.

    Everything after the host is dropped, because every REST path is
    appended to this value -- so a URL copied out of the browser address
    bar (.../jira/software/projects/ABC/boards/1) still resolves.
    """
    site = (raw or "").strip().rstrip("/")
    if not site:
        raise JiraError("The Jira site URL is required, "
                        "e.g. https://yourcompany.atlassian.net")
    if "://" not in site:
        site = "https://" + site
    parsed = urllib.parse.urlparse(site)
    if parsed.scheme not in ("http", "https"):
        raise JiraError(f"'{raw}' is not an http(s) URL.")
    if not parsed.netloc or "." not in parsed.netloc:
        raise JiraError(f"'{raw}' does not look like a Jira site URL, "
                        "e.g. https://yourcompany.atlassian.net")
    return f"{parsed.scheme}://{parsed.netloc}"


def normalize_email(raw):
    """
    The Atlassian account email. It is half of the Basic auth credential and
    the Keychain account name, so a typo here fails later as a 401 with
    nothing pointing back at the cause.
    """
    email = (raw or "").strip()
    if not email:
        raise JiraError("The Atlassian account email is required.")
    if any(c.isspace() for c in email):
        raise JiraError("The account email cannot contain spaces.")
    user, _, domain = email.partition("@")
    if not user or "." not in domain:
        raise JiraError(f"'{email}' does not look like an email address.")
    return email


def normalize_cloud_id(raw):
    """Empty means 'classic token': the key is removed rather than blanked."""
    cloud_id = (raw or "").strip()
    if any(c.isspace() for c in cloud_id):
        raise JiraError("The cloud id cannot contain spaces.")
    return cloud_id


def save_connection(site=None, email=None, cloud_id=None):
    """
    Writes the settings that were supplied and leaves the rest alone.
    Returns the resulting connection.

    Any change drops the issue cache: it holds results fetched for the old
    site, account or token routing, which would otherwise keep being served
    for the rest of the TTL and look like the new settings did nothing.
    """
    before = get_connection()
    updates = {}

    if site is not None:
        updates["jira_site"] = normalize_site(site)
    if email is not None:
        updates["jira_email"] = normalize_email(email)
    if cloud_id is not None:
        updates["jira_cloud_id"] = normalize_cloud_id(cloud_id)

    changed = False
    for key, value in updates.items():
        current = before[key[len("jira_"):]]
        if value == current:
            continue
        try:
            if value:
                set_setting(key, value)
            else:
                unset_setting(key)
        except ValueError as e:
            raise JiraError(str(e))
        changed = True

    if changed:
        clear_cache()
    return get_connection()


def get_jql():
    """The active JQL: whatever is configured, else the default."""
    return get_setting("jira_jql", DEFAULT_JQL)


def get_issue_limit():
    """How many issues to fetch at most. Bounded so a runaway query cannot
    page forever, but overridable for a genuinely large backlog."""
    raw = get_setting("jira_issue_limit")
    if raw is None:
        return DEFAULT_ISSUE_LIMIT
    try:
        value = int(str(raw).strip())
    except ValueError:
        return DEFAULT_ISSUE_LIMIT
    return max(PAGE_SIZE, min(value, 5000))


def is_default_jql():
    return not get_setting("jira_jql")


def set_jql(jql):
    """
    Persists a JQL query. The issue cache is dropped at the same time --
    otherwise the old query's results keep being served for up to the cache
    TTL and the new one looks like it did nothing.
    """
    jql = jql.strip()
    if not jql:
        raise JiraError("The JQL query is empty. Use --reset to restore the default.")
    try:
        set_setting("jira_jql", jql)
    except ValueError as e:
        raise JiraError(str(e))
    clear_cache()


def reset_jql():
    unset_setting("jira_jql")
    clear_cache()


# How many matches a validation run will count before it stops caring.
VALIDATE_SAMPLE = 100


def validate_jql(config, token, jql):
    """
    Runs the query before it is saved and reports how many issues it matches,
    as (count, is_exact).

    Two things make the count worth showing rather than just checking for an
    error. A syntax error does come back as a 400 with Jira's own
    explanation -- but an unknown field name does NOT: Jira accepts it and
    returns zero issues. A query that quietly matches nothing is the failure
    mode most worth catching, and the count is what exposes it.

    /rest/api/3/search/jql returns no 'total' (the enhanced endpoint dropped
    it), so the only honest count is the one we actually fetch.
    """
    params = {"jql": jql, "fields": "summary", "maxResults": VALIDATE_SAMPLE}
    data = _request(config, token, "/rest/api/3/search/jql", params)
    count = len(data.get("issues", []))
    is_exact = data.get("isLast") is True or count < VALIDATE_SAMPLE
    return count, is_exact


def get_token(email):
    """
    Reads the API token from the login Keychain. Returns None when absent.

    A non-zero exit means no such item. An item that exists but holds an
    empty value is a different fault entirely -- it used to be reported as
    'not stored', which sent you back to 'jott jira login' in a loop -- so
    say what it actually is.
    """
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-a", email, "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            return None
        token = result.stdout.strip()
        if not token:
            raise JiraError(
                "The Keychain item for Jira exists but is empty.\n"
                "  Run 'jott jira login' again to overwrite it."
            )
        return token
    except FileNotFoundError:
        raise JiraError("The 'security' command is unavailable; a macOS Keychain is required.")


def store_token(email, token):
    """
    Writes the token to the Keychain via `security -i`, which reads its
    sub-command from stdin -- so the token stays out of the process list,
    the same property the old interactive prompt was there to provide.

    What it must NOT do is use `security add-generic-password -w` with no
    value and pipe the token to the prompt. That path goes through
    readpassphrase, which:
      * prefers /dev/tty over stdin whenever a terminal is attached, so the
        piped token was ignored entirely and the stray newline getpass left
        in the tty buffer was stored as an EMPTY password; and
      * silently truncates at 128 bytes.
    Both faults still exit 0. Scoped Atlassian tokens run well past 128
    bytes, so every scoped login stored a corrupt value that looked saved.
    """
    if any(c.isspace() for c in token):
        raise JiraError(
            "That token contains a space or line break, which cannot be "
            "stored this way.\n  Check for a stray character in the paste."
        )

    command = f"add-generic-password -a {email} -s {KEYCHAIN_SERVICE} -U -w {token}\n"
    proc = subprocess.run(
        ["security", "-i"], input=command,
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise JiraError("Could not save the token to your Keychain.")

    # Read it back and compare. Every failure mode above exited 0, so the
    # round-trip is the only trustworthy confirmation.
    check = subprocess.run(
        ["security", "find-generic-password", "-a", email, "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True, check=False,
    )
    if check.returncode != 0 or check.stdout.strip() != token:
        raise JiraError(
            "The token did not survive the write to your Keychain "
            f"(stored {len(check.stdout.strip())} of {len(token)} characters)."
        )


def delete_token(email):
    subprocess.run(
        ["security", "delete-generic-password", "-a", email, "-s", KEYCHAIN_SERVICE],
        capture_output=True, text=True, check=False,
    )


# ======================================================================
# HTTP
# ======================================================================

def _api_base(config):
    """Scoped tokens are routed through api.atlassian.com; classic ones are not."""
    if config.get("cloud_id"):
        return f"https://api.atlassian.com/ex/jira/{config['cloud_id']}"
    return config["site"]


def _request(config, token, path, params=None):
    url = _api_base(config) + path
    if params:
        url += "?" + urllib.parse.urlencode(params)

    credentials = base64.b64encode(f"{config['email']}:{token}".encode()).decode()
    request = urllib.request.Request(url, headers={
        "Authorization": f"Basic {credentials}",
        "Accept": "application/json",
        "User-Agent": "jott-cli",
    })

    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 400:
            # A rejected JQL comes back as 400 with the parser's own
            # explanation, which is far more useful than the status code.
            raise JiraError(_error_detail(e) or "Jira rejected the request (400).")
        if e.code == 401:
            raise JiraError("Jira rejected your credentials (401). Re-run 'jott jira login'.")
        if e.code == 403:
            raise JiraError(
                "Jira refused the request (403). If you are using a scoped API token, "
                "confirm it has the 'read:jira-work' scope and that jira_cloud_id is set."
            )
        if e.code == 404:
            raise JiraError(f"Jira endpoint not found (404) at {url}. Check jira_site.")
        if e.code == 429:
            raise JiraError("Jira is rate limiting requests (429). Try again shortly.")
        raise JiraError(f"Jira returned HTTP {e.code}.")
    except urllib.error.URLError as e:
        raise JiraError(f"Could not reach Jira: {e.reason}")
    except json.JSONDecodeError:
        raise JiraError("Jira returned a response that could not be parsed as JSON.")


def _error_detail(http_error):
    """Pulls Jira's own errorMessages out of a failed response body."""
    try:
        body = json.loads(http_error.read().decode())
    except Exception:
        return None
    messages = body.get("errorMessages") or []
    if not messages and isinstance(body.get("errors"), dict):
        messages = list(body["errors"].values())
    return " ".join(str(m) for m in messages) or None


def verify(config, token):
    """Confirms the credentials work and returns the account's display name."""
    data = _request(config, token, "/rest/api/3/myself")
    return data.get("displayName") or data.get("emailAddress") or "unknown"


def fetch_issues(config, token, limit=None):
    """
    Pulls matching issues via the enhanced search endpoint, following every
    page up to `limit`. Returns (issues, truncated).

    Uses /rest/api/3/search/jql -- the legacy /rest/api/3/search was shut
    down through October 2025. This endpoint pages with nextPageToken rather
    than startAt, and returns no fields unless they are named.

    `truncated` is True only when the limit stopped a fetch that Jira still
    had more results for. It exists because the old behaviour -- one page,
    hard-stopped at 100 -- dropped the tail with no signal at all, so an
    issue that simply sorted past position 100 looked like a broken query.
    The server caps a single page at 100 no matter what maxResults asks for,
    so more than 100 issues always means more than one request.
    """
    if limit is None:
        limit = get_issue_limit()

    issues = []
    next_token = None
    more_available = False

    while len(issues) < limit:
        params = {
            "jql": config["jql"],
            "fields": "summary,status",
            "maxResults": min(PAGE_SIZE, limit - len(issues)),
        }
        if next_token:
            params["nextPageToken"] = next_token

        data = _request(config, token, "/rest/api/3/search/jql", params)

        for issue in data.get("issues", []):
            fields = issue.get("fields") or {}
            status = (fields.get("status") or {}).get("name") or ""
            issues.append({
                "key": issue.get("key", ""),
                "summary": fields.get("summary") or "",
                "status": status,
            })

        next_token = data.get("nextPageToken")
        if not next_token or data.get("isLast"):
            break

        # There is another page but no room left for it under the limit.
        if len(issues) >= limit:
            more_available = True

    return issues, more_available


# ======================================================================
# CACHE
# ======================================================================

def read_cache():
    try:
        with open(CACHE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return None


def write_cache(issues, truncated=False, limit=None):
    """The truncation flag is cached alongside the issues -- a warning that
    only appeared on a live fetch would vanish for the next 15 minutes."""
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(CACHE_FILE, "w") as f:
            json.dump({
                "issues": issues,
                "fetched_at": time.time(),
                "truncated": truncated,
                "limit": limit if limit is not None else get_issue_limit(),
            }, f)
    except Exception:
        pass  # A cache failure must never break the command


def clear_cache():
    """Drops the cached issue list so the next read refetches."""
    try:
        os.remove(CACHE_FILE)
    except FileNotFoundError:
        pass
    except OSError:
        pass


def cache_age(cache):
    if not cache or "fetched_at" not in cache:
        return None
    return time.time() - cache["fetched_at"]
