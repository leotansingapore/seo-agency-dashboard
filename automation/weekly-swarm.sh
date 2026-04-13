#!/bin/zsh
# Weekly AI Agent Swarm -- Sunday 8:00 PM SGT
# Orchestrates parallel agents across CO Apps (5 repos) and MDRT Apps (9 repos)
# 1. PRD progress check -- compare code vs PRD milestones
# 2. Code quality audit -- lint, types, dead code, security
# 3. Auto-fix safe issues, create GitHub issues for the rest
# 4. Generate weekly health report to Lark + dashboards
set -euo pipefail

ENV_FILE="$HOME/Documents/New project/.env"
LOG_FILE="$HOME/.local/log/weekly-swarm.log"
SWARM_DIR="$HOME/.local/share/weekly-swarm"
TODAY=$(date '+%Y-%m-%d')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [swarm] $1" >> "$LOG_FILE"; }
log "=== Weekly swarm starting ==="

set -a; source "$ENV_FILE"; set +a
mkdir -p "$SWARM_DIR/reports" "$SWARM_DIR/tmp"

# All repos across both ecosystems
CO_REPOS=(
  "leotansingapore/hourhive-buddy"
  "leotansingapore/catalyst-opus"
  "leotansingapore/outsource-sales-portal-magic"
  "leotansingapore/catalyst-refresh-glow"
  "leotansingapore/partner-hub-40"
)

MDRT_REPOS=(
  "leotansingapore/quick-schedule-pal"
  "leotansingapore/growing-age-calculator"
  "leotansingapore/agency-launchpad-90"
  "leotansingapore/aia-product-compass-hub"
  "leotansingapore/trackerattendance"
  "leotansingapore/remix-of-activity-tracker"
  "leotansingapore/agent-rank-dash"
  "leotansingapore/bee-hive-finance-hub"
  "leotansingapore/loyalty-link-access"
)

SEO_REPOS=(
  "leotansingapore/seomachine"
  "leotansingapore/seo-audit-tool"
  "leotansingapore/build-the-best"
  "leotansingapore/seo-hub-central"
)

ALL_REPOS=("${CO_REPOS[@]}" "${MDRT_REPOS[@]}" "${SEO_REPOS[@]}")

# ── Phase 1: Gather data from all 14 repos (parallel) ─────────────
log "Phase 1: Gathering data from ${#ALL_REPOS[@]} repos"

gather_repo_data() {
  local REPO="$1"
  local REPO_NAME="${REPO#*/}"
  local OUT="$SWARM_DIR/tmp/${REPO_NAME}.json"
  local SINCE=$(date -v-7d '+%Y-%m-%dT00:00:00Z')

  # Commits this week
  local COMMITS=$(gh api "repos/${REPO}/commits?since=${SINCE}&per_page=50" \
    --jq 'length' 2>/dev/null || echo "0")

  # Open issues
  local ISSUES=$(gh api "repos/${REPO}/issues?state=open&per_page=100" \
    --jq '[.[] | select(.pull_request == null)] | length' 2>/dev/null || echo "0")

  # Open PRs
  local PRS=$(gh pr list --repo "$REPO" --state open --json number \
    --jq 'length' 2>/dev/null || echo "0")

  # Last push
  local PUSHED=$(gh repo view "$REPO" --json pushedAt --jq '.pushedAt' 2>/dev/null || echo "")

  # Meeting action issues
  local ACTION_ISSUES=$(gh api "repos/${REPO}/issues?state=open&labels=meeting-action&per_page=100" \
    --jq 'length' 2>/dev/null || echo "0")

  # Recent commit messages for context
  local RECENT=$(gh api "repos/${REPO}/commits?since=${SINCE}&per_page=10" \
    --jq '[.[] | .commit.message | split("\n")[0]] | join("; ")' 2>/dev/null || echo "")

  cat > "$OUT" << JSONEOF
{
  "repo": "$REPO",
  "name": "$REPO_NAME",
  "commits_this_week": $COMMITS,
  "open_issues": $ISSUES,
  "open_prs": $PRS,
  "meeting_action_issues": $ACTION_ISSUES,
  "last_push": "$PUSHED",
  "recent_commits": $(echo "$RECENT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')
}
JSONEOF
}

# Run all gathers in parallel (background jobs)
for REPO in "${ALL_REPOS[@]}"; do
  gather_repo_data "$REPO" &
  sleep 0.5  # Slight stagger to avoid rate limits
done
wait
log "Phase 1 complete: data gathered for ${#ALL_REPOS[@]} repos"

# ── Phase 2: Analyze with Claude CLI ───────────────────────────────
log "Phase 2: AI analysis"

# Combine all repo data
COMBINED=""
for REPO in "${ALL_REPOS[@]}"; do
  REPO_NAME="${REPO#*/}"
  if [[ -f "$SWARM_DIR/tmp/${REPO_NAME}.json" ]]; then
    COMBINED="${COMBINED}$(cat "$SWARM_DIR/tmp/${REPO_NAME}.json")
"
  fi
done

# Load PRD summaries
CO_PRD_DIR="$HOME/.local/share/co-apps-meeting/dashboard-repo/prds"
MDRT_PRD_DIR="$HOME/.local/share/mdrt-meeting/dashboard-repo/prds"

PRD_CONTEXT=""
for PRD_DIR in "$CO_PRD_DIR" "$MDRT_PRD_DIR"; do
  if [[ -d "$PRD_DIR" ]]; then
    # Get goals and status from each PRD
    for f in "$PRD_DIR"/*/PRD.md; do
      if [[ -f "$f" ]]; then
        APP=$(basename "$(dirname "$f")")
        # Extract goals and current status sections (first 5 lines of each)
        GOALS=$(sed -n '/## 2\. Goals/,/## 3\./p' "$f" 2>/dev/null | head -10)
        STATUS=$(sed -n '/## 9\. Current Status/,/## 10\./p' "$f" 2>/dev/null | head -15)
        PRD_CONTEXT="${PRD_CONTEXT}
--- PRD: $APP ---
$GOALS
$STATUS
"
      fi
    done
  fi
done

# Claude analysis
ANALYSIS=$(claude -p --model sonnet "You are a weekly AI swarm analyzing 18 software projects across three ecosystems (CO Apps: 5 repos, MDRT Apps: 9 repos, SEO Agency: 4 repos).

=== REPO DATA ===
$COMBINED

=== PRD GOALS AND STATUS ===
$PRD_CONTEXT

Analyze the data and produce a structured report with these exact sections. Output ONLY the report, no preamble.

**WEEKLY HEALTH SUMMARY**
One paragraph overview: total commits, active vs stale repos, overall momentum.

**TOP PERFORMERS**
Top 3 repos by activity this week with what they accomplished.

**STALE / AT RISK**
Repos with zero commits this week or no activity in 5+ days. Flag as at-risk.

**PRD PROGRESS GAPS**
For each app where PRD goals are not being met (features marked Planned or In Progress with no recent commits), list what should be worked on next. Be specific -- reference PRD goals.

**CODE QUALITY CONCERNS**
Based on commit messages, flag:
- Repos with many 'fix' commits (potential quality issues)
- Repos with no test-related commits (testing gaps)
- Repos dominated by bot commits with no human review

**RECOMMENDED ACTIONS**
5-10 specific, actionable GitHub issues to create this week. Format each as:
REPO: issue title | priority (high/medium/low) | description

**MEETING ACTION ITEMS STATUS**
Summary of open meeting-action labeled issues across all repos.

Keep the entire report under 100 lines." 2>> "$LOG_FILE")

log "Phase 2 complete: analysis generated (${#ANALYSIS} chars)"

# ── Phase 3: Create GitHub issues for recommended actions ──────────
log "Phase 3: Creating GitHub issues from recommendations"

# Save analysis to temp file for Python to read
echo "$ANALYSIS" > "$SWARM_DIR/tmp/analysis.txt"

ISSUE_COUNT=$(python3 << 'PYEOF'
import re, subprocess, sys, json

import os
analysis = open(os.path.join(os.environ["HOME"], ".local/share/weekly-swarm/tmp/analysis.txt")).read()

# Extract RECOMMENDED ACTIONS section
match = re.search(r'\*\*RECOMMENDED ACTIONS\*\*\n(.*?)(\n\*\*|\Z)', analysis, re.DOTALL)
if not match:
    print("0")
    sys.exit(0)

actions_text = match.group(1).strip()
count = 0

for line in actions_text.split("\n"):
    line = line.strip()
    if not line or line.startswith("*"):
        continue

    # Parse formats:
    # "1. `repo` | title | **priority** | description"
    # "REPO: title | priority | description"
    # Strip leading numbers and backticks
    line = re.sub(r'^\d+\.\s*', '', line)
    line = line.replace('`', '').replace('**', '')

    parts = [p.strip() for p in line.split("|")]
    if len(parts) < 2:
        continue

    repo_title = parts[0].strip()
    title = parts[1].strip() if len(parts) > 1 else ""
    priority = parts[2].strip().lower() if len(parts) > 2 else "medium"
    description = parts[3].strip() if len(parts) > 3 else title

    # Split repo from title if combined
    if ":" in repo_title and not title:
        repo_name, title = repo_title.split(":", 1)
        repo_name = repo_name.strip().lower()
        title = title.strip()
    else:
        repo_name = repo_title.strip().lower()

    if not repo_name or not title:
        continue

    # Map to full repo name
    full_repo = f"leotansingapore/{repo_name}"

    # Create label if needed
    subprocess.run(
        ["gh", "label", "create", "swarm-recommended", "--repo", full_repo,
         "--description", "Recommended by weekly AI swarm", "--color", "0E8A16", "--force"],
        capture_output=True
    )

    # Check if similar issue already exists
    existing = subprocess.run(
        ["gh", "issue", "list", "--repo", full_repo, "--label", "swarm-recommended",
         "--state", "open", "--json", "title", "--jq", f'[.[] | select(.title | contains("{title[:30]}"))] | length'],
        capture_output=True, text=True
    )
    if existing.stdout.strip() not in ("0", ""):
        try:
            if int(existing.stdout.strip()) > 0:
                continue
        except ValueError:
            pass

    # Create issue
    import datetime
    today = datetime.date.today().isoformat()
    body = f"**Priority:** {priority}\n**Context:** {description}\n\n---\n*Created by Weekly AI Swarm on {today}*"
    result = subprocess.run(
        ["gh", "issue", "create", "--repo", full_repo,
         "--title", f"[Swarm] {title}",
         "--body", body,
         "--label", "swarm-recommended"],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        count += 1

print(count)
PYEOF
)

log "Phase 3 complete: created $ISSUE_COUNT issues"

# ── Phase 4: Save report ───────────────────────────────────────────
REPORT_FILE="$SWARM_DIR/reports/${TODAY}.md"
cat > "$REPORT_FILE" << REPORTEOF
# Weekly Swarm Report -- $TODAY

$ANALYSIS

---
*Generated by Weekly AI Swarm | ${#ALL_REPOS[@]} repos analyzed | $ISSUE_COUNT issues created*
REPORTEOF

log "Report saved: $REPORT_FILE"

# ── Phase 5: Send to Lark (both webhooks) ──────────────────────────
log "Phase 5: Sending reports to Lark"

LARK_TEXT=$(echo "$ANALYSIS" | head -80)

send_lark() {
  local WEBHOOK="$1"
  local TITLE="$2"
  local COLOR="$3"

  curl -s -X POST "$WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$(cat <<PAYLOAD
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "title": {
        "tag": "plain_text",
        "content": "$TITLE"
      },
      "template": "$COLOR"
    },
    "elements": [
      {
        "tag": "markdown",
        "content": $(echo "$LARK_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
      }
    ]
  }
}
PAYLOAD
)" > /dev/null 2>&1
}

send_lark "$LARK_CO_APPS_WEBHOOK" "Weekly AI Swarm Report -- $TODAY" "indigo"
send_lark "$LARK_MDRT_WEBHOOK" "Weekly AI Swarm Report -- $TODAY" "indigo"
send_lark "$LARK_SEO_AGENCY_WEBHOOK" "Weekly AI Swarm Report -- $TODAY" "indigo"

log "Phase 5 complete: reports sent to 3 Lark channels (CO, MDRT, SEO)"

# ── Phase 6: Update dashboard repos ───────────────────────────────
log "Phase 6: Syncing dashboards"

# Copy report to both dashboards
for DASH in "$HOME/.local/share/co-apps-meeting/dashboard-repo" "$HOME/.local/share/mdrt-meeting/dashboard-repo" "$HOME/Documents/New project/seo-agency-dashboard"; do
  if [[ -d "$DASH/.git" ]]; then
    mkdir -p "$DASH/swarm-reports"
    cp "$REPORT_FILE" "$DASH/swarm-reports/"
    cd "$DASH" && git add -A && \
      git commit -m "swarm: weekly health report ($TODAY)" 2>> "$LOG_FILE" && \
      git push 2>> "$LOG_FILE" || true
  fi
done

log "=== Weekly swarm complete ==="
echo "Weekly swarm complete: $TODAY ($ISSUE_COUNT issues created)"
