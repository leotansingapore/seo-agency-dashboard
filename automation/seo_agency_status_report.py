#!/usr/bin/env python3
"""
SEO Agency Ops -- PM Status Report
Runs Mon + Thu 9am SGT. Reports to Lark webhook + Google Sheet.

Covers 4 repos:
- seomachine (content engine)
- seo-audit-tool (audit dashboard)
- build-the-best (AutoSEO platform)
- seo-hub-central (agency CRM + portal)
"""

import json
import os
import subprocess
from datetime import datetime, timedelta, timezone

import requests

# --- Config ---
LARK_WEBHOOK = os.getenv(
    "LARK_SEO_AGENCY_WEBHOOK",
    "https://open.larksuite.com/open-apis/bot/v2/hook/05ffcb12-c056-4b9d-b7e3-8dbb7555fec4",
)
SHEET_ID = "17XNZrWmJqWY8fLq5NHSwpl_IiMIZwsBsZdz2uWfUYKw"
GH_USER = "leotansingapore"
REPOS = {
    "seomachine": {"role": "Content Engine", "path": "seomachine"},
    "seo-audit-tool": {"role": "Audit Dashboard", "path": "seo-audit-tool"},
    "build-the-best": {"role": "AutoSEO Platform", "path": "build-the-best"},
    "seo-hub-central": {"role": "Agency CRM + Portal", "path": "seo-hub-central"},
}
REPORT_WINDOW_DAYS = 4  # Mon covers Thu-Mon (4 days), Thu covers Mon-Thu (3 days)


def get_recent_commits(repo_name, days=REPORT_WINDOW_DAYS):
    """Fetch recent commits from GitHub."""
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        result = subprocess.run(
            [
                "gh",
                "api",
                f"repos/{GH_USER}/{repo_name}/commits",
                "--jq",
                f'[.[] | select(.commit.author.date >= "{since}") | {{sha: .sha[:7], msg: .commit.message | split("\\n")[0], date: .commit.author.date | split("T")[0]}}]',
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
    except Exception as e:
        print(f"  Warning: could not fetch commits for {repo_name}: {e}")
    return []


def get_open_issues(repo_name):
    """Fetch open issues count."""
    try:
        result = subprocess.run(
            [
                "gh",
                "api",
                f"repos/{GH_USER}/{repo_name}/issues",
                "--jq",
                "[.[] | select(.pull_request == null)] | length",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            return int(result.stdout.strip())
    except Exception:
        pass
    return 0


def get_open_prs(repo_name):
    """Fetch open PRs count."""
    try:
        result = subprocess.run(
            [
                "gh",
                "api",
                f"repos/{GH_USER}/{repo_name}/pulls",
                "--jq",
                "length",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            return int(result.stdout.strip())
    except Exception:
        pass
    return 0


def generate_ai_summary(all_data):
    """Use Claude CLI to generate a human-friendly PM summary."""
    commits_text = ""
    for repo_name, data in all_data.items():
        role = REPOS[repo_name]["role"]
        commits = data["commits"]
        if commits:
            commit_list = "\n".join(
                [f"  - {c['date']}: {c['msg']}" for c in commits[:10]]
            )
            commits_text += f"\n{repo_name} ({role}):\n{commit_list}\n"
        else:
            commits_text += f"\n{repo_name} ({role}): No commits in last {REPORT_WINDOW_DAYS} days\n"

    prompt = f"""You are a project manager reporting to your boss about the SEO Agency automation project.
Write a brief, human-friendly status report covering the last {REPORT_WINDOW_DAYS} days.

Context: We're building a fully autonomous SEO agency using 4 repos:
- seomachine: content engine (research, write, optimize, publish SEO articles)
- seo-audit-tool: client-facing audit dashboard (Next.js + Supabase)
- build-the-best: AutoSEO platform for client self-serve (React + Supabase, deployed on Lovable)
- seo-hub-central: agency CRM + client portal with task management, approvals, lead pipeline, GSC data (React + Supabase, deployed on Lovable)

Recent activity:
{commits_text}

Write exactly 3 sections, keep each to 2-3 bullet points max:
1. "What got done" -- concrete outcomes, not commit messages
2. "What's next" -- upcoming priorities based on the trajectory
3. "Needs attention" -- blockers, risks, or things that have gone quiet

Be concise. No fluff. Write like you're texting your boss, not writing a formal report.
If a repo has been quiet, flag it. Use plain language, not jargon."""

    try:
        result = subprocess.run(
            ["claude", "-p", "--model", "sonnet", prompt],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception as e:
        print(f"  Warning: Claude CLI summary failed: {e}")

    # Fallback: simple summary
    lines = []
    for repo_name, data in all_data.items():
        role = REPOS[repo_name]["role"]
        count = len(data["commits"])
        if count > 0:
            latest = data["commits"][0]["msg"]
            lines.append(f"**{repo_name}** ({role}): {count} commits. Latest: {latest}")
        else:
            lines.append(f"**{repo_name}** ({role}): No activity in last {REPORT_WINDOW_DAYS} days")
    return "\n".join(lines)


def send_lark_report(summary, all_data):
    """Send formatted report to Lark webhook."""
    now = datetime.now().strftime("%b %d, %Y %I:%M %p")

    # Build stats line
    stats_parts = []
    for repo_name, data in all_data.items():
        c = len(data["commits"])
        stats_parts.append(f"{repo_name}: {c} commits")
    stats_line = " | ".join(stats_parts)

    card = {
        "msg_type": "interactive",
        "card": {
            "header": {
                "title": {
                    "tag": "plain_text",
                    "content": f"SEO Agency Ops -- {now}",
                },
                "template": "blue",
            },
            "elements": [
                {
                    "tag": "markdown",
                    "content": f"**Last {REPORT_WINDOW_DAYS} days** | {stats_line}",
                },
                {"tag": "hr"},
                {"tag": "markdown", "content": summary},
                {"tag": "hr"},
                {
                    "tag": "markdown",
                    "content": f"[seomachine](https://github.com/{GH_USER}/seomachine) | [seo-audit-tool](https://github.com/{GH_USER}/seo-audit-tool) | [build-the-best](https://github.com/{GH_USER}/build-the-best) | [seo-hub-central](https://github.com/{GH_USER}/seo-hub-central)",
                },
            ],
        },
    }

    resp = requests.post(LARK_WEBHOOK, json=card, timeout=10)
    if resp.status_code == 200:
        body = resp.json()
        if body.get("code") == 0:
            print("Lark: report sent")
        else:
            print(f"Lark: API error: {body}")
    else:
        print(f"Lark: HTTP {resp.status_code}")


def append_to_google_sheet(summary, all_data):
    """Append a row to the Google Sheet via Zapier/Apps Script or gsheet CLI."""
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    total_commits = sum(len(d["commits"]) for d in all_data.values())

    repo_details = []
    for repo_name, data in all_data.items():
        c = len(data["commits"])
        issues = data["issues"]
        prs = data["prs"]
        repo_details.append(f"{repo_name}: {c} commits, {issues} issues, {prs} PRs")

    row_data = {
        "date": now,
        "total_commits": total_commits,
        "repo_breakdown": " | ".join(repo_details),
        "summary": summary.replace("\n", " ").replace("**", "")[:1000],
    }

    # Try using Claude's Zapier MCP to append to sheet
    try:
        result = subprocess.run(
            [
                "claude",
                "-p",
                "--model",
                "haiku",
                f'Append this row to Google Sheet ID {SHEET_ID}, sheet "Status Reports": Date="{row_data["date"]}", Total Commits={row_data["total_commits"]}, Repos="{row_data["repo_breakdown"]}", Summary="{row_data["summary"][:500]}". Use the google_sheets_create_spreadsheet_row Zapier tool.',
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode == 0:
            print("Google Sheet: row appended via Claude")
        else:
            print(f"Google Sheet: Claude append failed, saving locally")
            _save_local_backup(row_data)
    except Exception as e:
        print(f"Google Sheet: error: {e}")
        _save_local_backup(row_data)


def _save_local_backup(row_data):
    """Save report data locally as fallback."""
    backup_dir = os.path.expanduser("~/Documents/New project/.tmp")
    os.makedirs(backup_dir, exist_ok=True)
    backup_file = os.path.join(backup_dir, "seo_agency_reports.jsonl")
    with open(backup_file, "a") as f:
        f.write(json.dumps(row_data) + "\n")
    print(f"  Saved to {backup_file}")


def main():
    print(f"SEO Agency Status Report -- {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print(f"Window: last {REPORT_WINDOW_DAYS} days\n")

    all_data = {}
    for repo_name, info in REPOS.items():
        print(f"Fetching {repo_name} ({info['role']})...")
        commits = get_recent_commits(repo_name)
        issues = get_open_issues(repo_name)
        prs = get_open_prs(repo_name)
        all_data[repo_name] = {"commits": commits, "issues": issues, "prs": prs}
        print(f"  {len(commits)} commits, {issues} open issues, {prs} open PRs")

    print("\nGenerating AI summary...")
    summary = generate_ai_summary(all_data)
    print(f"\n{summary}\n")

    print("Sending to Lark...")
    send_lark_report(summary, all_data)

    print("Appending to Google Sheet...")
    append_to_google_sheet(summary, all_data)

    print("\nDone.")


if __name__ == "__main__":
    main()
