# SEO Agency Dashboard

Central ops hub for the autonomous SEO agency ecosystem. Contains automation scripts, meeting summaries, swarm reports, and PRDs.

## Ecosystem

| Repo | Role | Deployed |
|------|------|----------|
| [seomachine](https://github.com/leotansingapore/seomachine) | Content Engine -- research, write, optimize, publish | [Vercel Dashboard](https://dashboard-mu-swart-81.vercel.app) |
| [seo-audit-tool](https://github.com/leotansingapore/seo-audit-tool) | Audit Dashboard -- DataForSEO, Moz, Google Sheets | [Vercel](https://seo-audit-tool-leotansingapores-projects.vercel.app) |
| [build-the-best](https://github.com/leotansingapore/build-the-best) | AutoSEO Platform -- client self-serve | [Lovable](https://getautoseo.com) |
| [seo-hub-central](https://github.com/leotansingapore/seo-hub-central) | Agency CRM + Portal -- leads, tasks, approvals | Lovable |
| **[seo-agency-dashboard](https://github.com/leotansingapore/seo-agency-dashboard)** | **This repo** -- ops hub, automations, meetings | GitHub |

## Architecture

```
                seomachine (Content Engine)
               /        |        \         \
      /discover   /new-client  /publish   /client-report
      /analyze     /write      /autoseo
          v           |            v              v
  seo-audit-tool   Pipeline   build-the-best  seo-hub-central
  (Audit + KW)    topics->    (AutoSEO)       (Agency CRM)
  Google Sheets   draft->     receive-article  leads, tasks,
  Supabase        published   Supabase         approvals, GSC
     Vercel       qual gate     Lovable          Lovable
```

## Automation Schedule

| Job | Schedule (SGT) | Script | What |
|-----|---------------|--------|------|
| Status Report | Mon + Thu 9am | `seo_agency_status_report.py` | PM report to Lark + Google Sheet |
| Scrum Master | Mon + Fri 9:30am | `seo-agency-scrum-master.sh` | Meeting agenda to Lark (30min before 10am meeting) |
| Post-Meeting | Mon + Fri 11:30am | `seo-agency-post-meeting.sh` | Fireflies transcript -> attendance, summary, action items, GitHub issues |
| Content Ops | Weekdays 10am | Remote agent (Claude) | Move content through pipeline, daily ops log |
| Ralph | Daily 9/12/3/6/9 | `seo-agency-ralph-runner.sh` | Autonomous code improvements on seomachine + seo-hub-central |
| Weekly Swarm | Sun 8pm | `weekly-swarm.sh` | Cross-ecosystem health report (18 repos) |

## Meetings

**Schedule:** Monday + Friday 10:00 AM SGT
**Google Meet:** [meet.google.com/sqo-hzmo-iji](https://meet.google.com/sqo-hzmo-iji)
**Lark Channel:** SEO Agency Ops
**Google Sheet:** [Meeting Log + Status Reports](https://docs.google.com/spreadsheets/d/17XNZrWmJqWY8fLq5NHSwpl_IiMIZwsBsZdz2uWfUYKw)

Meeting summaries are auto-saved to `meetings/summaries/` after each meeting via Fireflies.

## Directory Structure

```
seo-agency-dashboard/
  automation/           # All automation scripts (copied from ~/.local/bin/)
  meetings/
    summaries/          # Auto-generated meeting summaries (YYYY-MM-DD.md)
  swarm-reports/        # Weekly AI swarm health reports
  prds/                 # Product requirement docs per repo
  README.md             # This file
```

## Ralph Autonomous Agent

Ralph runs on a 3-hour cycle improving seomachine and seo-hub-central. Each repo has a `.ralph/prd.json` backlog:

**seomachine stories:** Pipeline health API, client listing, auto-scrub, content calendar, quality scoring
**seo-hub-central stories:** GSC live API, article delivery webhook, audit task creation, health score, Lark notifications

When Ralph completes all stories, the auto-planner generates new ones based on codebase analysis.

## Quick Links

- [Ops Dashboard](https://dashboard-mu-swart-81.vercel.app) -- live repo status
- [Google Sheet](https://docs.google.com/spreadsheets/d/17XNZrWmJqWY8fLq5NHSwpl_IiMIZwsBsZdz2uWfUYKw) -- meeting log + status
- [Scheduled Agents](https://claude.ai/code/scheduled) -- remote Claude agents
- [Google Meet](https://meet.google.com/sqo-hzmo-iji) -- join meeting
