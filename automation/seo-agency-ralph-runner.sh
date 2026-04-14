#!/bin/zsh
# SEO Agency Ralph Runner -- autonomous improvement loop
#
# Runs Ralph across SEO agency repos that have .ralph/prd.json
# Pipeline:
#   1. Clone/pull to /tmp, check out ralph branch
#   2. Auto-planner: if prd.json queue empty, generate new stories
#   3. Ralph iteration: implement one story
#   4. Self-test: build check
#   5. Commit + push + create PR + auto-merge
#   6. Notify Lark
set -euo pipefail

# SEO Agency repos that Ralph can work on
SEO_REPOS=(
  "seomachine"
  "seo-hub-central"
)

LOG_FILE="$HOME/.local/log/seo-agency-ralph.log"
LOCK_FILE="/tmp/.ralph-seo-agency.lock"
LARK_WEBHOOK="https://open.larksuite.com/open-apis/bot/v2/hook/05ffcb12-c056-4b9d-b7e3-8dbb7555fec4"
SHEET_ID="17XNZrWmJqWY8fLq5NHSwpl_IiMIZwsBsZdz2uWfUYKw"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ralph] $1" | tee -a "$LOG_FILE"; }

heartbeat() {
  local job="$1"
  /usr/bin/python3 -c "
import sys, os, warnings
warnings.filterwarnings('ignore')
sys.path.insert(0, os.path.expanduser('~/Documents/New project/tools'))
try:
    from lib.heartbeat import beat
    beat('$job')
except Exception as e:
    print(f'heartbeat skipped: {e}')
" 2>> "$LOG_FILE" || true
}

# Prevent overlapping runs
if [[ -f "$LOCK_FILE" ]]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "Previous run still active (PID $LOCK_PID). Skipping."
    exit 0
  fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

notify_lark() {
  local title="$1"
  local content="$2"
  local template="${3:-blue}"
  python3 -c "
import json, urllib.request
payload = {
    'msg_type': 'interactive',
    'card': {
        'header': {'title': {'tag': 'plain_text', 'content': '$title'}, 'template': '$template'},
        'elements': [{'tag': 'markdown', 'content': '''$content'''}]
    }
}
req = urllib.request.Request('$LARK_WEBHOOK', data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
try: urllib.request.urlopen(req, timeout=5)
except: pass
" 2>/dev/null || true
}

append_sheet() {
  local repo="$1"
  local story_id="$2"
  local story_status="$3"
  local notes="${4:-}"
  /usr/bin/python3 << PYEOF 2>> "$LOG_FILE" || true
import sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.expanduser("~/Documents/New project/tools"))
try:
    from lib.sheets import get_sheets_client
    gc = get_sheets_client()
    ss = gc.open_by_key("$SHEET_ID")
    ws = ss.worksheet("Ralph Log")
    from datetime import datetime
    ws.append_row([datetime.now().strftime("%Y-%m-%d %H:%M"), "$repo", "$story_id", "", "$story_status", "$notes"])
except Exception as e:
    print(f"Ralph Log append failed: {e}")
PYEOF
}

append_blocker() {
  local repo="$1"
  local story_id="$2"
  local severity="$3"
  local blocker="$4"
  local action="${5:-Investigate logs}"
  /usr/bin/python3 << PYEOF 2>> "$LOG_FILE" || true
import sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.expanduser("~/Documents/New project/tools"))
try:
    from lib.sheets import get_sheets_client
    gc = get_sheets_client()
    ss = gc.open_by_key("$SHEET_ID")
    try:
        ws = ss.worksheet("Blockers")
    except Exception:
        ws = ss.add_worksheet(title="Blockers", rows=500, cols=8)
        ws.append_row(["Date","Repo","Source","Severity","Blocker","Story ID","Action Needed","Resolved"])
    from datetime import datetime
    ws.append_row([datetime.now().strftime("%Y-%m-%d %H:%M"), "$repo", "Ralph Runner", "$severity", "$blocker", "$story_id", "$action", "No"])
except Exception as e:
    print(f"Blockers append failed: {e}")
PYEOF
}

run_ralph_for_repo() {
  local REPO_NAME="$1"
  local REPO_URL="https://github.com/leotansingapore/${REPO_NAME}.git"
  local REPO_DIR="/tmp/ralph-${REPO_NAME}"

  log "=== Processing $REPO_NAME ==="

  # Clone or pull
  if [[ -d "$REPO_DIR/.git" ]]; then
    cd "$REPO_DIR"
    git fetch origin main 2>> "$LOG_FILE"
    git checkout main 2>> "$LOG_FILE"
    git pull origin main 2>> "$LOG_FILE"
  else
    rm -rf "$REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR" 2>> "$LOG_FILE"
    cd "$REPO_DIR"
  fi

  # Check for .ralph/prd.json
  if [[ ! -f ".ralph/prd.json" ]]; then
    log "$REPO_NAME: No .ralph/prd.json, skipping"
    return 0
  fi

  # Ingest any GitHub issues labeled 'ralph:ready' as new stories
  INGEST_OUT=$(/usr/bin/python3 << PYEOF 2>> "$LOG_FILE"
import json, subprocess, re, sys
try:
    r = subprocess.run(
        ["gh","issue","list","--repo","leotansingapore/$REPO_NAME","--label","ralph:ready",
         "--state","open","--json","number,title,body,labels","--limit","20"],
        capture_output=True, text=True, timeout=30)
    issues = json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else []
except Exception as e:
    print(f"  gh issue list failed: {e}", file=sys.stderr)
    issues = []

if not issues:
    print("0")
    sys.exit(0)

with open(".ralph/prd.json") as f:
    prd = json.load(f)
stories = prd.setdefault("userStories", [])
existing_issue_nums = {s.get("issueNumber") for s in stories if s.get("issueNumber")}

# Find next id prefix
ids = [s.get("id","") for s in stories]
prefixes = [re.match(r"([A-Z]+)-", i) for i in ids]
prefix = next((m.group(1) for m in prefixes if m), "ISSUE")
used_nums = [int(m.group(1)) for i in ids for m in [re.search(r"-(\d+)$", i)] if m]
next_num = max(used_nums, default=0) + 1

added = 0
for iss in issues:
    if iss["number"] in existing_issue_nums:
        continue
    labels = [l["name"] for l in iss.get("labels", [])]
    priority = 50 + iss["number"]  # put ingested at low priority by default
    for L in labels:
        if L.startswith("ralph:p"):
            try: priority = int(L.split("p")[1])
            except Exception: pass
    story = {
        "id": f"{prefix}-{next_num:03d}",
        "title": iss["title"][:120],
        "description": (iss.get("body") or iss["title"])[:1500],
        "acceptanceCriteria": ["Addresses the linked GitHub issue", "Build passes"],
        "priority": priority,
        "passes": False,
        "notes": f"Ingested from #{iss['number']}",
        "issueNumber": iss["number"],
    }
    stories.append(story)
    next_num += 1
    added += 1

if added:
    with open(".ralph/prd.json","w") as f:
        json.dump(prd, f, indent=2)
    # Commit the ingest so it persists across reruns
    subprocess.run(["git","add",".ralph/prd.json"], capture_output=True)
    subprocess.run(["git","commit","-m",f"ralph: ingest {added} issue(s) as stories"], capture_output=True)
print(added)
PYEOF
  )
  INGESTED=$(echo "$INGEST_OUT" | tail -1)
  if [[ "$INGESTED" =~ ^[0-9]+$ && "$INGESTED" -gt 0 ]]; then
    log "$REPO_NAME: ingested $INGESTED issue(s) as stories"
    git push origin main 2>> "$LOG_FILE" || true
  fi

  # Check for pending stories
  local PENDING=$(python3 -c "
import json
with open('.ralph/prd.json') as f:
    data = json.load(f)
pending = [s for s in data.get('userStories', []) if not s.get('passes', False)]
print(len(pending))
if pending:
    print(pending[0]['id'])
    print(pending[0]['title'])
" 2>/dev/null)

  local PENDING_COUNT=$(echo "$PENDING" | head -1)
  if [[ "$PENDING_COUNT" == "0" ]]; then
    log "$REPO_NAME: All stories complete, running auto-planner"

    # Auto-planner: generate new stories
    claude -p --model sonnet --permission-mode bypassPermissions \
      "You are Ralph's auto-planner for the $REPO_NAME repo. Read the codebase, check git log for recent changes, read .ralph/prd.json for completed stories, and analyze what improvements would be most valuable next.

Generate 3-5 new user stories and APPEND them to .ralph/prd.json (don't overwrite existing stories). Use the next available ID number. Focus on:
- Cross-repo integration improvements
- Content pipeline automation
- UI/UX improvements for the dashboard or portal
- Performance and reliability

Each story needs: id, title, description (As a... I want... so that...), acceptanceCriteria (array), priority (number), passes (false), notes (empty string).

Commit the updated prd.json with message 'ralph: auto-plan new stories for $REPO_NAME'." \
      2>> "$LOG_FILE" || true

    # Re-check after planning
    PENDING=$(python3 -c "
import json
with open('.ralph/prd.json') as f:
    data = json.load(f)
pending = [s for s in data.get('userStories', []) if not s.get('passes', False)]
print(len(pending))
if pending:
    print(pending[0]['id'])
    print(pending[0]['title'])
" 2>/dev/null)
    PENDING_COUNT=$(echo "$PENDING" | head -1)
  fi

  if [[ "$PENDING_COUNT" == "0" ]]; then
    log "$REPO_NAME: Still no pending stories after auto-plan. Done."
    return 0
  fi

  local STORY_ID=$(echo "$PENDING" | sed -n '2p')
  local STORY_TITLE=$(echo "$PENDING" | sed -n '3p')
  log "$REPO_NAME: Working on $STORY_ID -- $STORY_TITLE"

  # Checkout ralph branch
  git checkout -B ralph/autonomous 2>> "$LOG_FILE" || true

  # Notify start
  notify_lark "Ralph: $REPO_NAME" "Starting **$STORY_ID**: $STORY_TITLE\n$PENDING_COUNT stories remaining" "blue"

  # Lock prd.json for this repo (prevents concurrent auto-planner + ralph race)
  local PRD_LOCK="/tmp/.ralph-prd-${REPO_NAME}.lock"
  exec 200>"$PRD_LOCK"
  if ! /usr/bin/env python3 -c "import fcntl,sys; fcntl.flock(sys.stdin, fcntl.LOCK_EX|fcntl.LOCK_NB)" <&200 2>/dev/null; then
    log "$REPO_NAME: prd.json locked by another process, skipping"
    return 0
  fi

  # Run Ralph iteration with retry (up to 3 attempts, backoff 10s/30s)
  local RALPH_OUTPUT=""
  local ATTEMPT=0
  while [[ $ATTEMPT -lt 3 ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    RALPH_OUTPUT=$(claude -p --model sonnet --permission-mode bypassPermissions \
      "$(cat .ralph/PROMPT.md)" 2>> "$LOG_FILE" || echo "")
    if [[ -n "$RALPH_OUTPUT" && ${#RALPH_OUTPUT} -gt 50 ]]; then
      break
    fi
    log "$REPO_NAME: Ralph attempt $ATTEMPT returned empty/short output, retrying..."
    sleep $((ATTEMPT * 10))
  done

  if [[ -z "$RALPH_OUTPUT" || ${#RALPH_OUTPUT} -lt 50 ]]; then
    log "$REPO_NAME: Ralph returned empty output after 3 attempts"
    append_blocker "$REPO_NAME" "$STORY_ID" "HIGH" "Ralph claude CLI returned empty output x3 (possible auth issue under launchd)" "Run claude -p manually in shell; check claude CLI auth and launchd PATH"
    return 0
  fi

  # Check for status block
  if echo "$RALPH_OUTPUT" | grep -q "EXIT_SIGNAL: true"; then
    log "$REPO_NAME: Ralph signaled exit"
  fi

  if echo "$RALPH_OUTPUT" | grep -q "STATUS: BLOCKED"; then
    log "$REPO_NAME: Ralph is blocked"
    notify_lark "Ralph BLOCKED: $REPO_NAME" "$STORY_ID is blocked. Check logs." "yellow"
    append_sheet "$REPO_NAME" "$STORY_ID" "BLOCKED"
    append_blocker "$REPO_NAME" "$STORY_ID" "HIGH" "Ralph reported STATUS: BLOCKED on $STORY_ID" "Review $LOG_FILE and unblock story or rewrite acceptance criteria"
    return 0
  fi

  # Self-test (only if npm is available)
  local BUILD_OK=true
  if command -v npm &>/dev/null; then
    if [[ -f "dashboard/package.json" ]]; then
      cd dashboard && npm run build 2>> "$LOG_FILE" || BUILD_OK=false
      cd "$REPO_DIR"
    elif [[ -f "package.json" ]]; then
      npm run build 2>> "$LOG_FILE" || BUILD_OK=false
    fi
  else
    log "$REPO_NAME: npm not in PATH, skipping build check"
  fi

  if [[ "$BUILD_OK" == "false" ]]; then
    log "$REPO_NAME: Build failed after Ralph. Reverting."
    git checkout main 2>> "$LOG_FILE"
    notify_lark "Ralph BUILD FAIL: $REPO_NAME" "$STORY_ID build failed. Reverted." "red"
    append_sheet "$REPO_NAME" "$STORY_ID" "BUILD_FAIL"
    append_blocker "$REPO_NAME" "$STORY_ID" "HIGH" "Build failed after Ralph implemented $STORY_ID (changes reverted)" "Check build errors in $LOG_FILE and fix manually or revise story"
    return 0
  fi

  # Commit + push
  git add -A 2>> "$LOG_FILE"
  if git diff --cached --quiet 2>/dev/null; then
    log "$REPO_NAME: No changes to commit (Ralph thought but did not write)"
    append_sheet "$REPO_NAME" "$STORY_ID" "NO_CHANGES" "Ralph produced no file writes"
    append_blocker "$REPO_NAME" "$STORY_ID" "MEDIUM" "Ralph produced no file diffs for $STORY_ID (prompt unclear or blocked)" "Clarify acceptanceCriteria in .ralph/prd.json or split the story"
    return 0
  fi

  git commit -m "feat: ralph completes $STORY_ID -- $STORY_TITLE

Co-Authored-By: Ralph (autonomous) <noreply@anthropic.com>" 2>> "$LOG_FILE"

  git push origin ralph/autonomous --force 2>> "$LOG_FILE"

  # Create PR + auto-merge (skip if one already exists for this branch)
  local EXISTING_PR=$(gh pr list --repo "leotansingapore/$REPO_NAME" \
    --head ralph/autonomous --state open --json url --jq '.[0].url' 2>/dev/null || echo "")
  if [[ -n "$EXISTING_PR" ]]; then
    log "$REPO_NAME: PR already exists: $EXISTING_PR"
    notify_lark "Ralph DONE: $REPO_NAME" "Completed **$STORY_ID**: $STORY_TITLE\nExisting PR: $EXISTING_PR" "green"
    append_sheet "$REPO_NAME" "$STORY_ID" "COMPLETED"
    git checkout main 2>> "$LOG_FILE"
    return 0
  fi

  local PR_URL=$(gh pr create --repo "leotansingapore/$REPO_NAME" \
    --base main --head ralph/autonomous \
    --title "[Ralph] $STORY_ID: $STORY_TITLE" \
    --body "Autonomous improvement by Ralph.

**Story:** $STORY_ID
**Description:** $STORY_TITLE
**Status:** Build passing

---
*Auto-generated by SEO Agency Ralph Runner*" 2>> "$LOG_FILE" || echo "")

  if [[ -n "$PR_URL" ]]; then
    gh pr merge --repo "leotansingapore/$REPO_NAME" --squash --delete-branch 2>> "$LOG_FILE" || {
      log "$REPO_NAME: Auto-merge failed, PR left open for manual review"
    }
    log "$REPO_NAME: PR created and auto-merge requested: $PR_URL"
  fi

  # Notify completion
  notify_lark "Ralph DONE: $REPO_NAME" "Completed **$STORY_ID**: $STORY_TITLE\nPR: $PR_URL\n$((PENDING_COUNT - 1)) stories remaining" "green"
  append_sheet "$REPO_NAME" "$STORY_ID" "COMPLETED"

  # If this story was ingested from a GitHub issue, close it
  ISSUE_NUM=$(/usr/bin/python3 -c "
import json
try:
    with open('.ralph/prd.json') as f: prd = json.load(f)
    for s in prd.get('userStories', []):
        if s.get('id') == '$STORY_ID' and s.get('issueNumber'):
            print(s['issueNumber']); break
except Exception: pass
" 2>/dev/null)
  if [[ -n "$ISSUE_NUM" ]]; then
    gh issue close "$ISSUE_NUM" --repo "leotansingapore/$REPO_NAME" \
      --comment "Resolved by Ralph: $STORY_ID via $PR_URL" 2>> "$LOG_FILE" || \
      log "$REPO_NAME: issue #$ISSUE_NUM close failed"
    log "$REPO_NAME: closed linked issue #$ISSUE_NUM"
  fi

  # Switch back to main
  git checkout main 2>> "$LOG_FILE"
}

# ── Main ──────────────────────────────────────────────────────────
log "=== SEO Agency Ralph Runner starting ==="

for REPO in "${SEO_REPOS[@]}"; do
  run_ralph_for_repo "$REPO" || log "Error processing $REPO, continuing..."
done

log "=== SEO Agency Ralph Runner complete ==="
heartbeat "seo-agency-ralph-runner"
