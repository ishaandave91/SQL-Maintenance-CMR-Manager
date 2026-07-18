---
name: read_cmrs_daily
description: >
  Fetch the previous 2 days' <JIRA_CHANGE_TYPE_LABEL> CMR tickets from the <JIRA_INSTANCE_URL>
  Jira instance and save them to a local CSV file for use by update_cmrs_daily. Filters
  by project CMR, Change Type = <JIRA_CHANGE_TYPE_LABEL>, and Planned Start Date within the
  previous 2-day window (so maintenances that completed the day after their start — e.g.
  a job that ran 11 PM to 3 AM — are still picked up on a later run). Use this skill
  whenever the user asks to read, fetch, pull, or retrieve CMRs from Jira, or when
  preparing data for the daily CMR update workflow.
compatibility:
  tools:
    - atlassian
  allowed-tools:
    - mcp__atlassian__searchJiraIssuesUsingJql
    - mcp__atlassian__getJiraIssue
    - mcp__atlassian__atlassianUserInfo
---

# /read_cmrs_daily — Fetch the Previous 2 Days' <JIRA_CHANGE_TYPE_LABEL> CMRs

Queries Jira for all **<JIRA_CHANGE_TYPE_LABEL>** CMRs whose Planned Start Date falls within the **previous 2 days**, then saves them to a local CSV for `update_cmrs_daily`. The 2-day window (not just yesterday) ensures a maintenance that starts late and finishes the next day — e.g. 11 PM → 3 AM — is revisited once its actual completion time is recorded.

---

## Constants (this Jira instance)

- **cloudId:** `<JIRA_CLOUD_ID>`
- **Base URL:** https://<JIRA_INSTANCE_URL>
- **project key: `<JIRA_PROJECT_KEY>`
- **Issue type:** `CMR`
- **Change Type filter:** `<JIRA_CHANGE_TYPE_LABEL>`

Field IDs (mapped to CSV columns in Step 4): `<JIRA_CF_CHANGE_TYPE>` Change Type, `<JIRA_CF_LOCATION>` Location, `<JIRA_CF_AFFECTED_SYSTEMS>` Affected Systems, `<JIRA_CF_PLANNED_START>` Planned Start, `<JIRA_CF_PLANNED_END>` Planned End.

> **JQL note:** Always use `cf[<JIRA_CF_PLANNED_START_ID>]` (or `<JIRA_CF_PLANNED_START>`) for date filtering — this instance returns zero results for the named form `"Planned Start Date"`.

---

## Environment Defaults

- **Timezone:** `America/Chicago`. DST-aware: CDT (UTC-5) mid-March through early November, CST (UTC-6) the rest of the year.
- **Week starts on:** Monday.

---

## Step 1: Determine the Previous 2-Day Window

Calculate the window covering the **previous 2 days** relative to today (the two days before today; today itself is excluded). Execute the below PowerShell command — do not calculate dates manually:

```powershell
# Fetch the window bounds: window_start = 2 days ago, window_end = yesterday
"window_start=$((Get-Date).AddDays(-2).ToString('yyyy-MM-dd')) window_end=$((Get-Date).AddDays(-1).ToString('yyyy-MM-dd'))"
```

**Example:** If today is 2026-05-26, then `window_start` = 2026-05-24 and `window_end` = 2026-05-25, so the filter becomes 2026-05-24 00:00 to 2026-05-25 23:59.

Capture `window_start` and `window_end` in `YYYY-MM-DD` format — you'll use them in the JQL, the log filename, and the CSV filename.

---

## Step 2: Initialize Log File

Create the log file **before** making any API calls so every operation is captured from the start.

- **Log directory (relative):** `.claude/skills/read_cmrs_daily/logs/`
- **Log filename:** `YYYY-MM-DD_HH-MM-SS.log` (timestamp at run start)
- If a log file with the same timestamp already exists, append to it rather than overwriting.

Log the run start, calculated date, and each key operation as it happens (fetch attempt, record count, CSV write result, errors).

---

## Step 3: Fetch CMR Issues from Jira

Use `mcp__atlassian__searchJiraIssuesUsingJql` with the following JQL:

```jql
project = <JIRA_PROJECT_KEY>
  AND "Change Type" = "<JIRA_CHANGE_TYPE_LABEL>"
  AND cf[<JIRA_CF_PLANNED_START_ID>] >= "{window_start} 00:00"
  AND cf[<JIRA_CF_PLANNED_START_ID>] <= "{window_end} 23:59"
ORDER BY cf[<JIRA_CF_PLANNED_START_ID>] ASC
```

Replace `{window_start}` and `{window_end}` with the dates from Step 1 (e.g., `"2026-05-24 00:00"` and `"2026-05-25 23:59"`).

**Request these fields** (only those written to the CSV in Step 4 — do not request `description` or `issuetype`; they are not persisted and only inflate the response):

```
summary, status, created, assignee, reporter,
<JIRA_CF_CHANGE_TYPE>, <JIRA_CF_LOCATION>, <JIRA_CF_AFFECTED_SYSTEMS>, <JIRA_CF_PLANNED_START>, <JIRA_CF_PLANNED_END>
```

Log the number of records returned. If the API call fails, log the error with full details and stop — do not write a partial CSV.

---

## Step 4: Save Results to CSV

**Data directory (relative):** `.claude/skills/read_cmrs_daily/data/`

**Base filename:** `{window_start}_to_{window_end}.csv` (e.g., `2026-05-24_to_2026-05-25.csv`)

If that base name already exists, append an incrementing suffix (`_1`, `_2`, …) — never overwrite.

**CSV column order (write exactly these headers, in this order):**

| CSV Column | Jira Field | Notes |
|---|---|---|
| `Key` | issue key | e.g., `<JIRA_PROJECT_KEY>-NNN` |
| `Summary` | `summary` | |
| `Status` | `status.name` | |
| `Reporter` | `reporter.displayName` | |
| `Assignee` | `assignee.displayName` | empty string if unassigned |
| `Change Type` | `<JIRA_CF_CHANGE_TYPE>.value` | |
| `Location` | `<JIRA_CF_LOCATION>.value` | |
| `Affected Systems` | `<JIRA_CF_AFFECTED_SYSTEMS>` | |
| `Planned Start` | `<JIRA_CF_PLANNED_START>` | ISO 8601 as returned |
| `Planned End` | `<JIRA_CF_PLANNED_END>` | ISO 8601 as returned |
| `Created` | `created` | ISO 8601 as returned |

If no records were returned by the JQL, still write the file with only the header row. Log this outcome.

Log the final CSV path and row count written.

---

## Anti-patterns to Avoid

- **Do not use the named form for Planned Start in JQL.** Use `cf[<JIRA_CF_PLANNED_START_ID>]`; the named form returns zero results.
- **Do not write a partial CSV on API failure.** Log the error and stop without writing an incomplete file.
- **Do not hardcode absolute Windows paths.** All paths are relative to the project root.
- **Do not silently overwrite an existing file.** Increment the suffix instead — prior data may be needed for audit/reprocessing.
- **Do not skip the log initialization.** Create the log in Step 2, before the first API call, so fetch failures are captured.
