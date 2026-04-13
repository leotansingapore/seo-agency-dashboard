#!/bin/zsh
# SEO Agency Post-Meeting Analyzer -- Monday + Friday after 10am meetings
# Fetches Fireflies transcript, extracts attendance + summary + action items
# Writes to Google Sheet tabs, sends Lark summary, saves to Obsidian
set -euo pipefail

ENV_FILE="$HOME/Documents/New project/.env"
STATE_DIR="$HOME/.local/share/seo-agency-meeting"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$HOME/.local/log/seo-agency-meeting.log"
OBSIDIAN_DIR="$HOME/Documents/Obsidian Vault/Meetings/SEO Agency"
SHEET_ID="17XNZrWmJqWY8fLq5NHSwpl_IiMIZwsBsZdz2uWfUYKw"
LARK_WEBHOOK="https://open.larksuite.com/open-apis/bot/v2/hook/05ffcb12-c056-4b9d-b7e3-8dbb7555fec4"
TODAY=$(date '+%Y-%m-%d')
DOW=$(date '+%u')  # 1=Mon, 5=Fri

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [post-meeting] $1" >> "$LOG_FILE"; }
log "Starting SEO Agency post-meeting analysis"

set -a; source "$ENV_FILE"; set +a
mkdir -p "$STATE_DIR" "$OBSIDIAN_DIR"

if [[ ! -f "$STATE_FILE" ]]; then
  echo '{"action_items":[],"processed_transcripts":[],"attendance_log":[]}' > "$STATE_FILE"
fi

TMPDIR_REPORT=$(mktemp -d)
trap "rm -rf $TMPDIR_REPORT" EXIT

# ── 1. Find the SEO Agency meeting transcript ────────────────────
find_transcript() {
  python3 << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone, timedelta
from urllib.request import Request, urlopen

API_KEY = os.environ["FIREFLIES_API_KEY"]
SGT = timezone(timedelta(hours=8))

query = """{
    transcripts(limit: 20) {
        id
        title
        date
        duration
        organizer_email
        summary {
            overview
            action_items
        }
    }
}"""

req = Request(
    "https://api.fireflies.ai/graphql",
    data=json.dumps({"query": query}).encode(),
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"},
)

try:
    resp = urlopen(req, timeout=60)
    data = json.loads(resp.read())
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

transcripts = data.get("data", {}).get("transcripts", [])

# Match by title
for t in transcripts:
    title = (t.get("title") or "").lower()
    if "seo" in title and ("agency" in title or "hub" in title or "machine" in title):
        print(json.dumps({"id": t["id"]}))
        sys.exit(0)

# Fallback: Monday/Friday 10-11am SGT window
today_str = datetime.now(SGT).strftime("%Y-%m-%d")
dow = datetime.now(SGT).weekday()  # 0=Mon, 4=Fri
for t in transcripts:
    ts = t.get("date", 0)
    if isinstance(ts, str):
        continue
    dt = datetime.fromtimestamp(ts / 1000, tz=SGT)
    if dt.strftime("%Y-%m-%d") == today_str and dt.weekday() in (0, 4):
        if 10 <= dt.hour <= 11:
            print(json.dumps({"id": t["id"]}))
            sys.exit(0)

# Check Google Meet link match
for t in transcripts:
    ts = t.get("date", 0)
    if isinstance(ts, str):
        continue
    dt = datetime.fromtimestamp(ts / 1000, tz=SGT)
    if dt.strftime("%Y-%m-%d") == today_str:
        title = (t.get("title") or "").lower()
        if "sqo-hzmo-iji" in title:
            print(json.dumps({"id": t["id"]}))
            sys.exit(0)

sys.exit(1)
PYEOF
}

TRANSCRIPT_INFO=""
for attempt in $(seq 1 6); do
  log "Poll attempt $attempt/6 for Fireflies transcript"
  TRANSCRIPT_INFO=$(find_transcript 2>/dev/null || echo "")
  if [[ -n "$TRANSCRIPT_INFO" ]]; then break; fi
  if [[ $attempt -lt 6 ]]; then
    log "Transcript not ready, waiting 10 minutes..."
    sleep 600
  fi
done

if [[ -z "$TRANSCRIPT_INFO" ]]; then
  log "No SEO Agency meeting transcript found. Exiting."
  exit 0
fi

TRANSCRIPT_ID=$(echo "$TRANSCRIPT_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
PARTICIPANTS=""  # Will be extracted from transcript speakers later

# Check already processed
if python3 -c "
import json
d = json.load(open('$STATE_FILE'))
exit(0 if '$TRANSCRIPT_ID' in d.get('processed_transcripts', []) else 1)
" 2>/dev/null; then
  log "Transcript $TRANSCRIPT_ID already processed. Skipping."
  exit 0
fi

log "Found transcript: $TRANSCRIPT_ID (participants: $PARTICIPANTS)"

# ── 2. Fetch full transcript ─────────────────────────────────────
TRANSCRIPT=$(python3 << PYEOF
import json, os, sys
from urllib.request import Request, urlopen

API_KEY = os.environ["FIREFLIES_API_KEY"]

query = """{
    transcript(id: "$TRANSCRIPT_ID") {
        title
        audio_url
        video_url
        participants
        sentences {
            text
            speaker_name
        }
        summary {
            overview
            shorthand_bullet
            action_items
        }
    }
}"""

req = Request(
    "https://api.fireflies.ai/graphql",
    data=json.dumps({"query": query}).encode(),
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"},
)

resp = urlopen(req, timeout=120)
data = json.loads(resp.read())

td = data.get("data", {}).get("transcript", {})
sentences = td.get("sentences", [])
summary = td.get("summary", {})
participants = td.get("participants", [])
recording = td.get("video_url") or td.get("audio_url") or ""

print(f"TITLE: {td.get('title', 'SEO Agency Meeting')}")
print(f"RECORDING_URL: {recording}")
print(f"PARTICIPANTS: {', '.join(participants) if participants else 'Unknown'}")
print(f"SUMMARY: {summary.get('overview', 'N/A')}")
print("---TRANSCRIPT---")

# Unique speakers for attendance
speakers = set()
lines = []
for s in sentences:
    speaker = s.get("speaker_name", "Unknown")
    text = s.get("text", "")
    if text.strip():
        speakers.add(speaker)
        lines.append(f"{speaker}: {text}")

print(f"SPEAKERS: {', '.join(sorted(speakers))}")

if len(lines) > 500:
    lines = lines[len(lines)//5:]
print("\\n".join(lines))
PYEOF
)

if [[ -z "$TRANSCRIPT" ]]; then
  log "Failed to fetch transcript"
  exit 1
fi

log "Transcript fetched ($(echo "$TRANSCRIPT" | wc -l | tr -d ' ') lines)"

# Extract attendance info
SPEAKERS=$(echo "$TRANSCRIPT" | grep "^SPEAKERS:" | sed 's/^SPEAKERS: //')
MEETING_TITLE=$(echo "$TRANSCRIPT" | head -1 | sed 's/^TITLE: //')
RECORDING_URL=$(echo "$TRANSCRIPT" | grep "^RECORDING_URL:" | sed 's/^RECORDING_URL: //')

echo "$TRANSCRIPT" > "$TMPDIR_REPORT/transcript.txt"

# ── 3. Analyze with Claude ───────────────────────────────────────
log "Analyzing transcript"

ANALYSIS=$(claude -p --model sonnet "$(cat "$TMPDIR_REPORT/transcript.txt")

You are a scrum master analyzing an SEO Agency team meeting transcript.

The agency builds autonomous SEO using 4 repos:
- [seomachine](https://github.com/leotansingapore/seomachine): Content engine
- [seo-audit-tool](https://github.com/leotansingapore/seo-audit-tool): Audit dashboard
- [build-the-best](https://github.com/leotansingapore/build-the-best): AutoSEO platform
- [seo-hub-central](https://github.com/leotansingapore/seo-hub-central): Agency CRM

Extract (use ** for bold headings):

**Attendance**
List who attended based on the speakers in the transcript.

**Meeting Summary**
3-5 sentence overview.

**Key Decisions**
List decisions with context.

**Action Items**
Who, what, which repo. Be specific.

**Blockers Discussed**
Any issues blocking progress.

**Follow-ups for Next Meeting**
Items to check on Monday/Friday.

At the end, output a JSON array of action items:
\`\`\`json
[{\"assignee\":\"Name\",\"description\":\"Task\",\"repo\":\"repo-name-or-general\"}]
\`\`\`" 2>> "$LOG_FILE")

log "Analysis complete"

# ── 4. Log attendance to Google Sheet ────────────────────────────
log "Logging attendance + summary to Google Sheet"

python3 << PYEOF
import subprocess, json
from datetime import datetime

sheet_id = "$SHEET_ID"
today = "$TODAY"
speakers = "$SPEAKERS"
meeting_type = "Monday Standup" if datetime.now().weekday() == 0 else "Friday Review"

# Create/append attendance + summary to sheet
summary_text = """$ANALYSIS"""[:800].replace('"', "'").replace('\n', ' | ')

prompt = f"""Use the Zapier Google Sheets tools to do these two things on Sheet ID {sheet_id}:

1. Find or create a sheet tab called "Meeting Log". If it doesn't exist, create it with headers: Date, Type, Attendees, Summary, Action Items, Recording.

2. Append a new row to the "Meeting Log" tab with:
   - Date: {today}
   - Type: {meeting_type}
   - Attendees: {speakers}
   - Summary: {summary_text[:400]}
   - Action Items: (extract from the summary)
   - Recording: $RECORDING_URL

Use google_sheets_create_spreadsheet_row or google_sheets_lookup_spreadsheet_row as needed."""

subprocess.run(
    ["claude", "-p", "--model", "haiku", prompt],
    capture_output=True, text=True, timeout=90
)
print("Sheet updated")
PYEOF

# ── 5. Create GitHub issues from action items ────────────────────
log "Creating GitHub issues"

python3 << PYEOF
import json, re, subprocess, sys

analysis = """$ANALYSIS"""
match = re.search(r'\`\`\`json\s*\n(.*?)\n\`\`\`', analysis, re.DOTALL)
if not match:
    sys.exit(0)

try:
    actions = json.loads(match.group(1))
except json.JSONDecodeError:
    sys.exit(0)

repo_prefix = "leotansingapore/"
seo_repos = ["seomachine", "seo-audit-tool", "build-the-best", "seo-hub-central"]

for item in actions:
    repo_short = item.get("repo", "general")
    if repo_short not in seo_repos:
        repo_short = "seomachine"
    repo = f"{repo_prefix}{repo_short}"
    desc = item.get("description", "")
    assignee = item.get("assignee", "")

    subprocess.run(
        ["gh", "label", "create", "meeting-action", "--repo", repo,
         "--description", "Action from SEO Agency meeting", "--color", "D93F0B", "--force"],
        capture_output=True
    )

    body = f"**Assigned to:** {assignee}\n**Meeting:** $TODAY\n\n---\n*Created by SEO Agency Meeting Bot*"
    subprocess.run(
        ["gh", "issue", "create", "--repo", repo,
         "--title", f"[Meeting] {desc}", "--body", body, "--label", "meeting-action"],
        capture_output=True, text=True
    )
PYEOF

# ── 6. Update state ─────────────────────────────────────────────
python3 << PYEOF
import json
state = json.load(open("$STATE_FILE"))
state["processed_transcripts"].append("$TRANSCRIPT_ID")
state["processed_transcripts"] = state["processed_transcripts"][-20:]
state["attendance_log"].append({"date": "$TODAY", "speakers": "$SPEAKERS"})
state["attendance_log"] = state["attendance_log"][-50:]
state["last_meeting_date"] = "$TODAY"
json.dump(state, open("$STATE_FILE", "w"), indent=2)
PYEOF

# ── 7. Save to Obsidian ─────────────────────────────────────────
cat > "$OBSIDIAN_DIR/${TODAY} SEO Agency Meeting.md" << OBSEOF
---
date: $TODAY
type: meeting-notes
meeting: SEO Agency
source: fireflies
transcript_id: $TRANSCRIPT_ID
attendees: $SPEAKERS
---

# SEO Agency Meeting -- $TODAY

$ANALYSIS
OBSEOF

# ── 8. Send to Lark ─────────────────────────────────────────────
LARK_TEXT=$(echo "$ANALYSIS" | sed '/^```json/,/^```$/d' | head -60)

curl -s -X POST "$LARK_WEBHOOK" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json, sys
text = sys.stdin.read()
card = {
    'msg_type': 'interactive',
    'card': {
        'header': {'title': {'tag': 'plain_text', 'content': 'SEO Agency Meeting Summary -- $TODAY'}, 'template': 'green'},
        'elements': [
            {'tag': 'markdown', 'content': text},
            {'tag': 'hr'},
            {'tag': 'markdown', 'content': '**Attendees:** $SPEAKERS\n**Sheet:** [Meeting Log](https://docs.google.com/spreadsheets/d/$SHEET_ID)'}
        ]
    }
}
print(json.dumps(card))
" <<< "$LARK_TEXT")" > /dev/null 2>&1

# ── 9. Save summary to dashboard repo ────────────────────────────
DASH_REPO="$HOME/Documents/New project/seo-agency-dashboard"
if [[ -d "$DASH_REPO/.git" ]]; then
  mkdir -p "$DASH_REPO/meetings/summaries"
  cp "$OBSIDIAN_DIR/${TODAY} SEO Agency Meeting.md" "$DASH_REPO/meetings/summaries/${TODAY}.md"
  cd "$DASH_REPO" && git add -A && \
    git commit -m "meeting: SEO Agency summary ($TODAY)" 2>> "$LOG_FILE" && \
    git push 2>> "$LOG_FILE" || true
  log "Summary pushed to seo-agency-dashboard"
fi

log "=== SEO Agency post-meeting complete ==="
echo "SEO Agency post-meeting done: $TODAY (attendees: $SPEAKERS)"
