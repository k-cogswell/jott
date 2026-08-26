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

from .config import get_setting, CONFIG_FILE, CLR_TITLE, CLR_HEAD, CLR_CMD, CLR_TEXT, CLR_RESET, CLR_BOLD

KEYCHAIN_SERVICE = "jott-jira"
CACHE_DIR = os.path.expanduser("~/.cache/jott")
CACHE_FILE = os.path.join(CACHE_DIR, "jira-issues.json")
CACHE_TTL_SECONDS = 900  # 15 minutes
REQUEST_TIMEOUT = 15

DEFAULT_JQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"


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
            f"  Add these to {CONFIG_FILE}:\n"
            '      jira_site = "https://yourcompany.atlassian.net"\n'
            '      jira_email = "you@company.com"\n'
            "  Then run: jott jira login"
        )
    return {
        "site": site.rstrip("/"),
        "email": email,
        "cloud_id": get_setting("jira_cloud_id"),
        "jql": get_setting("jira_jql", DEFAULT_JQL),
    }


def get_token(email):
    """Reads the API token from the login Keychain. Returns None when absent."""
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-a", email, "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            return None
        return result.stdout.strip() or None
    except FileNotFoundError:
        raise JiraError("The 'security' command is unavailable; a macOS Keychain is required.")


def store_token(email, token):
    """
    Writes the token to the Keychain. The value is piped over stdin (twice,
    which is what interactive -w expects) rather than passed as an argument,
    so it never appears in the process list.
    """
    proc = subprocess.run(
        ["security", "add-generic-password", "-a", email, "-s", KEYCHAIN_SERVICE, "-U", "-w"],
        input=f"{token}\n{token}\n", capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise JiraError("Could not save the token to your Keychain.")


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


def verify(config, token):
    """Confirms the credentials work and returns the account's display name."""
    data = _request(config, token, "/rest/api/3/myself")
    return data.get("displayName") or data.get("emailAddress") or "unknown"


def fetch_issues(config, token, limit=100):
    """
    Pulls assigned issues via the enhanced search endpoint.

    Uses /rest/api/3/search/jql -- the legacy /rest/api/3/search was shut
    down through October 2025. This endpoint pages with nextPageToken
    rather than startAt, and returns no fields unless they are named.
    """
    issues = []
    next_token = None

    while len(issues) < limit:
        params = {
            "jql": config["jql"],
            "fields": "summary,status",
            "maxResults": min(100, limit - len(issues)),
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

    return issues


# ======================================================================
# CACHE
# ======================================================================

def read_cache():
    try:
        with open(CACHE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return None


def write_cache(issues):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(CACHE_FILE, "w") as f:
            json.dump({"issues": issues, "fetched_at": time.time()}, f)
    except Exception:
        pass  # A cache failure must never break the command


def cache_age(cache):
    if not cache or "fetched_at" not in cache:
        return None
    return time.time() - cache["fetched_at"]
