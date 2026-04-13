#!/bin/zsh
# SEO Agency Scrum Master -- Monday + Friday 10:00 AM SGT -> Lark
# Fires at 9:30am to have the agenda ready by 10am meeting time
# Fetches GitHub activity from 4 SEO repos, generates meeting agenda via Claude CLI
# Google Meet: meet.google.com/sqo-hzmo-iji
set -euo pipefail

REPOS=(
  "leotansingapore/seomachine"
  "leotansingapore/seo-audit-tool"
  "leotansingapore/build-the-best"
  "leotansingapore/seo-hub-central"
)

REPO_ROLES=(
  "Content Engine (research, write, optimize, publish)"
  "Audit Dashboard (DataForSEO, Moz, Google Sheets)"
  "AutoSEO Platform (client self-serve, Lovable)"
  "Agency CRM + Portal (leads, tasks, approvals, Lovable)"
)

ENV_FILE="$HOME/Documents/New project/.env"
STATE_DIR="$HOME/.local/share/seo-agency-meeting"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$HOME/.local/log/seo-agency-meeting.log"
TODAY=$(date '+%Y-%m-%d')
SINCE=$(date -v-7d '+%Y-%m-%dT00:00:00Z')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [seo-scrum] $1" >> "$LOG_FILE"; }
log "Starting SEO Agency scrum master report"

# Load env
set -a; source "$ENV_FILE"; set +a
mkdir -p "$STATE_DIR"

# Initialize state file if missing
if [[ ! -f "$STATE_FILE" ]]; then
  echo '{"action_items":[],"last_report":""}' > "$STATE_FILE"
fi

# Temp dir with cleanup
TMPDIR_REPORT=$(mktemp -d)
trap "rm -rf $TMPDIR_REPORT" EXIT

# ── 1. Fetch GitHub data per repo ─────────────────────────────────
echo "=== SEO AGENCY WEEKLY STATUS ===" > "$TMPDIR_REPORT/context.txt"
echo "Report date: $TODAY" >> "$TMPDIR_REPORT/context.txt"
echo "Period: last 7 days (since $SINCE)" >> "$TMPDIR_REPORT/context.txt"
echo "" >> "$TMPDIR_REPORT/context.txt"

TOTAL_COMMITS=0
IDX=1

for REPO in "${REPOS[@]}"; do
  REPO_NAME="${REPO#*/}"
  ROLE="${REPO_ROLES[$IDX]}"
  IDX=$((IDX + 1))
  log "Fetching data for $REPO_NAME"

  echo "--- REPO: $REPO_NAME ($ROLE) ---" >> "$TMPDIR_REPORT/context.txt"
  echo "URL: https://github.com/${REPO}" >> "$TMPDIR_REPORT/context.txt"

  # Recent commits
  COMMITS=$(gh api "repos/${REPO}/commits?since=${SINCE}&per_page=50" \
    --jq '.[] | "- \(.commit.message | split("\n")[0]) (\(.commit.author.name), \(.commit.author.date[:10]))"' 2>/dev/null || echo "")

  if [[ -n "$COMMITS" ]]; then
    COMMIT_COUNT=$(echo "$COMMITS" | wc -l | tr -d ' ')
    TOTAL_COMMITS=$((TOTAL_COMMITS + COMMIT_COUNT))
    echo "Commits ($COMMIT_COUNT):" >> "$TMPDIR_REPORT/context.txt"
    echo "$COMMITS" >> "$TMPDIR_REPORT/context.txt"
  else
    echo "Commits: None in last 7 days" >> "$TMPDIR_REPORT/context.txt"
  fi

  # Open PRs
  OPEN_PRS=$(gh pr list --repo "$REPO" --state open --json number,title,author \
    --jq '.[] | "- #\(.number): \(.title) (@\(.author.login))"' 2>/dev/null || echo "")
  if [[ -n "$OPEN_PRS" ]]; then
    echo "Open PRs:" >> "$TMPDIR_REPORT/context.txt"
    echo "$OPEN_PRS" >> "$TMPDIR_REPORT/context.txt"
  fi

  # Open issues
  OPEN_ISSUES=$(gh api "repos/${REPO}/issues?state=open&per_page=20" \
    --jq '.[] | select(.pull_request == null) | "- #\(.number): \(.title) [\(.labels | map(.name) | join(", "))]"' 2>/dev/null || echo "")
  if [[ -n "$OPEN_ISSUES" ]]; then
    echo "Open Issues:" >> "$TMPDIR_REPORT/context.txt"
    echo "$OPEN_ISSUES" >> "$TMPDIR_REPORT/context.txt"
  fi

  # Staleness check
  PUSHED_AT=$(gh repo view "$REPO" --json pushedAt --jq '.pushedAt' 2>/dev/null || echo "")
  if [[ -n "$PUSHED_AT" ]]; then
    echo "Last push: $PUSHED_AT" >> "$TMPDIR_REPORT/context.txt"
    PUSH_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${PUSHED_AT}" "+%s" 2>/dev/null || echo "0")
    NOW_EPOCH=$(date "+%s")
    DAYS_AGO=$(( (NOW_EPOCH - PUSH_EPOCH) / 86400 ))
    if [[ $DAYS_AGO -gt 5 ]]; then
      echo "WARNING: STALE -- no push in ${DAYS_AGO} days" >> "$TMPDIR_REPORT/context.txt"
    fi
  fi

  echo "" >> "$TMPDIR_REPORT/context.txt"
done

# Load outstanding action items from state
ACTION_ITEMS=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
items = state.get('action_items', [])
if items:
    print('Outstanding action items from last week:')
    for item in items:
        print(f\"- [{item.get('status','open')}] {item.get('description','')}\")
else:
    print('No outstanding action items.')
" 2>/dev/null || echo "No state file.")

echo "--- CARRYOVER ---" >> "$TMPDIR_REPORT/context.txt"
echo "$ACTION_ITEMS" >> "$TMPDIR_REPORT/context.txt"

# ── 2. Generate agenda via Claude CLI ─────────────────────────────
log "Generating scrum agenda via Claude CLI"

CONTEXT=$(cat "$TMPDIR_REPORT/context.txt")

AGENDA=$(claude -p --model sonnet "You are the scrum master for an autonomous SEO agency with 4 repos.
Meetings: Monday + Friday 10am SGT | Google Meet: meet.google.com/sqo-hzmo-iji

The agency's goal: replace manual SEO agency work with fully autonomous AI agents.
System architecture: seomachine (content engine) orchestrates seo-audit-tool (audits), build-the-best (AutoSEO delivery), and seo-hub-central (CRM + client portal).

=== THIS WEEK'S DATA ===
$CONTEXT

Generate a weekly scrum agenda. Write like you're a PM briefing your boss. Plain language, no fluff.

Format with these exact sections:

**This Week at a Glance**
- Total commits, which repos were active, which were quiet
- One sentence momentum assessment

**What Got Done**
- 3-5 specific accomplishments grouped by repo
- Focus on outcomes, not commit messages

**Cross-Repo Integration Status**
- Are the bridge modules (seo_audit_bridge.py, autoseo_bridge.py) being used?
- Any content flowing through the pipeline? (topics -> research -> drafts -> published)
- Is the CRM (seo-hub-central) receiving any leads or tasks?

**Blockers & Risks**
- Stale repos (no activity 5+ days)
- Integration gaps
- Missing credentials or config

**Action Items for This Week**
- 5-7 specific, assignable action items with priority (high/medium/low)
- Focus on: onboarding first client, connecting data sources, getting content pipeline flowing

**Ralph Autonomous Agent Recommendations**
- Which repos would benefit from Ralph autonomous improvement loops?
- Suggest 3-5 user stories for each repo's prd.json

Keep under 80 lines. No preamble or sign-off." 2>> "$LOG_FILE" || echo "**Claude CLI failed -- raw data below**

$CONTEXT")

if [[ -z "$AGENDA" ]]; then
  AGENDA="**Claude CLI unavailable -- raw repo data:**

$CONTEXT"
  log "WARNING: Claude CLI failed, using raw context as fallback"
fi

log "Agenda generated (${#AGENDA} chars)"

# ── 3. Send to Lark ───────────────────────────────────────────────
log "Sending to Lark"

LARK_TEXT=$(echo "$AGENDA" | head -80)

curl -s -X POST "$LARK_SEO_AGENCY_WEBHOOK" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json, sys
text = sys.stdin.read()
card = {
    'msg_type': 'interactive',
    'card': {
        'header': {
            'title': {'tag': 'plain_text', 'content': 'SEO Agency Scrum -- $TODAY'},
            'template': 'blue'
        },
        'elements': [
            {'tag': 'markdown', 'content': text},
            {'tag': 'hr'},
            {'tag': 'markdown', 'content': '**Join:** [Google Meet](https://meet.google.com/sqo-hzmo-iji)\n**Repos:** [seomachine](https://github.com/leotansingapore/seomachine) | [seo-audit-tool](https://github.com/leotansingapore/seo-audit-tool) | [build-the-best](https://github.com/leotansingapore/build-the-best) | [seo-hub-central](https://github.com/leotansingapore/seo-hub-central)'}
        ]
    }
}
print(json.dumps(card))
" <<< "$LARK_TEXT")" > /dev/null 2>&1

log "Lark card sent"

# ── 4. Update Google Sheet ────────────────────────────────────────
log "Updating Google Sheet"

python3 << PYEOF
import subprocess, json, sys
from datetime import datetime

sheet_id = "17XNZrWmJqWY8fLq5NHSwpl_IiMIZwsBsZdz2uWfUYKw"
today = datetime.now().strftime("%Y-%m-%d %H:%M")
total_commits = $TOTAL_COMMITS
summary = """$AGENDA"""[:500].replace('"', "'")

# Use Claude CLI to append via Zapier
subprocess.run(
    ["claude", "-p", "--model", "haiku",
     f'Append a row to Google Sheet ID {sheet_id}, sheet "Status Reports": Date="{today}", Total Commits={total_commits}, Type="Scrum", Summary="{summary}". Use the google_sheets_create_spreadsheet_row Zapier tool.'],
    capture_output=True, text=True, timeout=60
)
PYEOF

# ── 5. Extract action items for next week's state ─────────────────
python3 << PYEOF
import json, re
agenda = """$AGENDA"""
# Extract action items section
match = re.search(r'\*\*Action Items.*?\*\*\n(.*?)(\n\*\*|\Z)', agenda, re.DOTALL)
items = []
if match:
    for line in match.group(1).strip().split('\n'):
        line = line.strip().lstrip('- ').lstrip('0123456789. ')
        if line and len(line) > 5:
            items.append({"description": line, "status": "open", "created": "$TODAY"})

state = {"action_items": items, "last_report": "$TODAY"}
with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYEOF

log "State updated with action items"
log "=== SEO Agency scrum master complete ==="
echo "SEO Agency scrum complete: $TODAY ($TOTAL_COMMITS commits)"
