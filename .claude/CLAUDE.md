# CLAUDE.md

Use this file for guidance when working with code in this repository.

## Guidelines
- Always prefer PowerShell over Bash
- Always use `py` instead of `python` or `python3` to invoke Python scripts
- Never modify, edit or run any code, server object, Windows object or any critical configuration without permission
- Consider start of the week as Monday
- Always use snake_case for variable, function, method, slash commands and class names
- Use descriptive names that clearly indicate purpose of the object

## Running Python Scripts

```powershell
# Fetch scheduled maintenances for a week (used by create_cmrs skill)
py .claude\skills\create_cmrs\scripts\fetchCMRsForNextWeek.py --start-date 2026-06-01 --end-date 2026-06-08

# Fetch actual completion times from previous day (used by update_cmrs_daily skill)
py .claude\skills\update_cmrs_daily\scripts\fetchCompletedMaintDetails.py --start-date 2026-05-31 --end-date 2026-06-01
```

Both scripts require ODBC Driver 17 for SQL Server and Windows Trusted Connection to `<source_server>`.

## Architecture

This project automates Jira CMR (Change Management Request) ticket management for SQL scheduled maintenances. It is a Claude Code–native pipeline: all orchestration is handled by Claude skills and MCP tool calls — there is no standalone application server.

### Data Flow

```
SQL Server (<source_server>)
  └─► fetchCMRsForNextWeek.py  ──► CSV  ──► Jira createJiraIssue  (create_cmrs)
  └─► fetchCompletedMaintDetails.py ──► matched to CSV ──► Jira editJiraIssue  (update_cmrs_daily)
Jira JQL query  ──► CSV  (read_cmrs_daily)
Jira JQL query  ──► Jira editJiraIssue (assignee → null)  (update_assignees)
Skill data/ & logs/ dirs  ──► age check (>14 days) ──► Remove-Item  (purge_data_logs)
```

### Five-Skill Pipeline

Orchestrated by `.claude/agents/cmr_orchestrator/cmr_orchestrator.md` and triggered via `/run_orchestrator` or `/run_orchestrator_preview`. Weekly cadence is driven by a scheduled routine (not an in-project calendar reminder).

| Skill | Runs On | Purpose |
|---|---|---|
| `create_cmrs` | Any day | Creates Jira CMR issues for the target Mon–Sun week (Sunday → next week, else current week). Prevents duplicates via a per-row Jira pre-check (Step 4.5) on top of the CSV-file guard |
| `read_cmrs_daily` | Any day | Fetches previous day's CMRs from Jira → saves to CSV |
| `update_cmrs_daily` | Any day | Patches `customfield_10309` (Planned End) with actual completion times from SQL; for `MaintStatus = 'Skipped'` rows also prepends skip notice to description |
| `update_assignees` | Any day | Clears the backend's auto-assignment on all future-dated Scheduled Maintenance CMRs that currently have an assignee (sets `assignee` → `null`). Runs before the cleanup step so the time gap lets the auto-assignment settle |
| `purge_data_logs` | Any day | Deletes CSV and log files older than 14 days from the `data/` and `logs/` directories of all four Jira management skill folders. Always runs **last** so cleanup never interferes with any Jira operation |

Skill definitions live in `.claude/skills/{skill_name}/SKILL.md`. Each skill is self-contained with its own `data/` and `logs/` subdirectories.

### External Integrations

- **SQL Server** — Windows Trusted Connection; server `<source_server>`; view `<database_name>.[dbo].<table_name>`
- **Jira** — `<atlassian_endpoint>`, project key `CMR`, cloudId `<organization_cloud_id>`; accessed via Atlassian MCP

### Field ID Mappings

Use `{"id": "<id>"}` for select-type fields; plain strings for text fields. The values this project uses: **Change Type** (`<field_id>`) → Scheduled Maintenance `<field_id>`; **Location** (`<field_id>`) → DC-Dallas `<field_id>`, DC-Waco `<field_id>`; **components** → DBOps `<field_id>`.

### Date & Timezone Conventions

- Timezone: `America/Chicago` (CDT = UTC−5; CST = UTC−6)
- Datetime format for Jira: `"2026-05-27T08:00:00.000-0500"`
- Week: Monday (start) through Sunday (end)
- CSV filenames use `YYYY-MM-DD` (daily) or `YYYY-MM-DD_to_YYYY-MM-DD` (weekly)
- If a CSV already exists for a date, append `_1`, `_2`, etc. — never overwrite

## File Naming Conventions

- Python scripts: `snake_case.py`
- CSV data files: `YYYY-MM-DD.csv` or `YYYY-MM-DD_to_YYYY-MM-DD.csv`
- Log files: `YYYY-MM-DD_HH-MM-SS.log`

## Directory Structure Rules

Each skill follows this layout:
```
.claude/skills/{skill_name}/
  SKILL.md          # skill definition and execution instructions
  scripts/          # Python helper scripts (if any)
  data/             # CSV outputs
  logs/             # execution logs
```

