---
name: update_cmrs_daily
description: >
  Update the Planned End Date/Time (<JIRA_CF_PLANNED_END>) on the previous 2 days' SQL
  Maintenance CMR tickets in <JIRA_INSTANCE_URL> Jira, using actual completion
  times fetched from a SQL Server view. For tickets where MaintStatus = 'Skipped',
  also updates the description to prepend "This maintenance had been skipped."
  Reads the previous 2 days' CMR list from the CSV produced by read_cmrs_daily,
  matches each issue by Affected Systems/Servers, previews the proposed changes,
  and applies edits after confirmation. The 2-day window catches maintenances that
  completed the day after their start. Use this skill whenever the user asks to
  update, patch or correct CMRs for completed maintenances, or when syncing actual
  end times back to Jira after maintenance windows have run.
compatibility:
  tools:
    - atlassian
  allowed-tools:
    - mcp__atlassian__searchJiraIssuesUsingJql
    - mcp__atlassian__getJiraIssue
    - mcp__atlassian__editJiraIssue
    - mcp__atlassian__lookupJiraAccountId
    - mcp__atlassian__atlassianUserInfo
---

# /update_cmrs_daily — Update Planned End Date/Time for Completed Maintenances

Reads the previous 2 days' CMR list (produced by `read_cmrs_daily`) and actual completion times from a SQL Server view, then updates `<JIRA_CF_PLANNED_END>` (Planned End Date/Time) on each matched Jira issue after user confirmation. The 2-day window catches a maintenance that finishes the day after it starts (e.g. 11 PM → 3 AM); re-processing is safe because Step 6 stages an update only when the end time actually differs.

---

## Constants (this Jira instance)

- **cloudId:** `<JIRA_CLOUD_ID>`
- **Base URL:** https://<JIRA_INSTANCE_URL>
- **project key: `<JIRA_PROJECT_KEY>`
- **Issue type:** `CMR`

### Field ID Reference

| Field ID | Name | Format |
|---|---|---|
| `<JIRA_CF_PLANNED_START>` | Planned Start Date/Time | ISO 8601 with CDT offset: `"2026-05-20T08:00:00.000-0500"` |
| `<JIRA_CF_PLANNED_END>` | Planned End Date/Time | Same format — this is the field being updated |
| `<JIRA_CF_AFFECTED_SYSTEMS>` | Affected Systems | Plain text — used as the match key between CSV rows |

---

## Environment Defaults

- **Timezone:** `America/Chicago`. DST-aware: CDT (UTC-5) mid-March through early November, CST (UTC-6) the rest of the year.
- **Week starts on:** Monday.

---

## Step 1: Determine the Previous 2-Day Window

Calculate the window covering the **previous 2 days** relative to today (the two days before today; today itself is excluded) — this must match the window `read_cmrs_daily` used. Execute the below PowerShell command — do not calculate dates manually:

```powershell
# window_start = 2 days ago, window_end = yesterday, sql_end_exclusive = today (exclusive upper bound for the SQL fetch)
"window_start=$((Get-Date).AddDays(-2).ToString('yyyy-MM-dd')) window_end=$((Get-Date).AddDays(-1).ToString('yyyy-MM-dd')) sql_end_exclusive=$((Get-Date).ToString('yyyy-MM-dd'))"
```

Capture `window_start`, `window_end`, and `sql_end_exclusive` in `YYYY-MM-DD` format.

**Example:** If today is 2026-05-26, then `window_start` = 2026-05-24, `window_end` = 2026-05-25, and `sql_end_exclusive` = 2026-05-26.

`window_start`/`window_end` locate the relevant CSV file from `/read_cmrs_daily` (named `{window_start}_to_{window_end}.csv`). `window_start` and `sql_end_exclusive` are the parameters for the SQL fetch in Step 5.

---

## Step 2: Select staged updates file if already exists

Scan the directory - .claude\skills\update_cmrs_daily\data for files matching the previous 2-day window. Use `window_start`/`window_end` from Step 1 to construct the expected filename pattern:

**Filename pattern:** `staged_updates_{window_start}_to_{window_end}*.csv`

If multiple files match (e.g., `_1`, `_2` suffixes), select the **highest suffix** — the most recent run.

If a **matching file** exists for the window: skip steps 3 to 7 and jump directly to **Step 8: Apply Jira Edits** — its existence means steps 3 to 7 already ran and the staged edits are confirmed.
If **no file** exists for the window: then continue the normal flow and go to the next step- Step 3.

## Step 3: Initialize Log File

Create the log file before any file reads or API calls so that all operations — including early failures — are captured.

- **Log directory (relative):** `.claude/skills/update_cmrs_daily/logs/`
- **Log filename:** `YYYY-MM-DD_HH-MM-SS.log` (timestamp at run start)

Log: run start, calculated date range, and each key operation as it happens (file reads, SQL fetch, match outcomes, edit results, errors).

---

## Step 4: Locate the Previous 2-Day Window's CMR CSV

Scan `.claude/skills/read_cmrs_daily/data/` for files matching the previous 2-day window. Use `window_start`/`window_end` from Step 1 to construct the expected filename pattern:

**Filename pattern:** `{window_start}_to_{window_end}*.csv`

If multiple files match (e.g., `_1`, `_2` suffixes), select the **highest suffix** — the most recent run.

If **no file** exists for the window: log this, notify the user, and stop — `read_cmrs_daily` must run first.

Log the selected file path and its row count.

---

## Step 5: Fetch Actual Completion Times from SQL Server

Run the Python script to pull completion details for the previous 2-day window:

```
py .claude\skills\update_cmrs_daily\scripts\fetchCompletedMaintDetails.py --start-date {window_start} --end-date {sql_end_exclusive}
```

Where `--start-date` = `window_start` (inclusive, 2 days ago) and `--end-date` = `sql_end_exclusive` (today, **exclusive** upper bound) — so the fetch covers the two prior days and excludes today. Example: today 2026-05-26 → `--start-date 2026-05-24 --end-date 2026-05-26`.

The script emits the rows as **CSV on stdout** (the row count prints separately on stderr). From that output, extract and hold these columns in memory (do not write a new CSV unless you find it necessary for debugging):

| Column from script | Purpose |
|---|---|
| `Key` | Maintenance identifier (for logging) |
| `Summary` | Human-readable description |
| `Planned Start` | Actual start time (ISO 8601 CDT) |
| `Planned End` | **Actual end time — maps to `<JIRA_CF_PLANNED_END>`** (ISO 8601 CDT, e.g. `"2026-05-20T09:30:00.000-0500"`) |
| `Location` | DC location (for logging) |
| `Affected Systems` | Match key — must align with `<JIRA_CF_AFFECTED_SYSTEMS>` in the Jira issue |
| `MaintStatus` | Maintenance status from SQL — drives whether the Jira description is also updated (see Step 7) |

> `Planned End` from the SQL view is the **actual** completion time for the maintenance. It replaces the originally scheduled end time in Jira.

Log the number of rows returned by the script.

---

## Step 6: Match CSV Rows to SQL Completion Records and save staged updates

For each row in the CMR CSV (from Step 4):

1. Look up the row's `Affected Systems` value in the SQL result set (from Step 5), matching on the `Affected Systems` column (case-insensitive, trim whitespace).
2. **If a match is found:** stage the update — capture the Jira `Key`, current `Planned End` from the CSV, and proposed new `Planned End` from the SQL result. **Compare only down to the minute:** truncate both the CSV `Planned End` and the SQL `Planned End` to `YYYY-MM-DDTHH:MM` (drop seconds and sub-seconds) before comparing. Stage the row **only if these minute-level values differ** — a difference in seconds alone is **not** a change: log `"No change was needed for: <Affected Systems value>"` and **skip it**. When staging, also normalize the proposed `Planned End` to minute precision (seconds = `00`, e.g. `2026-05-20T09:47:00.000-0500`) so Jira never stores a sub-minute value. Notify the user in the final summary.
3. **If no match is found:** log a warning for that row (`"No completion record found for: <Affected Systems value>"`) and **skip it** — do not halt the entire run. Notify the user in the final summary.

After processing all rows, you have a list of staged updates (matched) and a list of skipped rows (unmatched).
Save all this data to a new csv file, keeping the list of skipped rows at the end.

**CSV columns (write exactly these headers, in this order):**

| Column | Content |
|---|---|
| `Jira Key` | Jira issue key, e.g. `<JIRA_PROJECT_KEY>-NNN` |
| `Affected Systems` | Match key value from `<JIRA_CF_AFFECTED_SYSTEMS>` |
| `Current Planned End` | ISO 8601 value currently on the Jira issue (from the read_cmrs_daily CSV) |
| `Proposed Planned End` | ISO 8601 actual completion time from SQL, **normalized to minute precision** (seconds = `00`); maps to `<JIRA_CF_PLANNED_END>` |
| `MaintStatus` | Value from SQL `MaintStatus` column; empty for unmatched rows |
| `Status` | `staged` for matched rows; `skipped` for unmatched rows |
| `Skip Reason` | Populated only for skipped rows (e.g. `"No completion record found"`); empty for staged rows |

**Data directory (relative):** `.claude/skills/update_cmrs_daily/data/`

**Base filename:** `staged_updates_{window_start}_to_{window_end}.csv` (e.g., `staged_updates_2026-05-24_to_2026-05-25.csv`)

If that base name already exists, append an incrementing suffix (`_1`, `_2`, …) — never overwrite.

---

## Step 7: Preview Proposed Changes and Confirm

Display a table of all staged updates before any Jira API calls:

| # | Jira Key | Affected Systems | Current Planned End (CT) | Proposed Planned End (CT) | MaintStatus | Description Update |
|---|----------|-----------------|--------------------------|---------------------------|-------------|--------------------|
| 1 | <JIRA_PROJECT_KEY>-NNN | sql-prod-01 | 2026-05-20 09:00 CDT | 2026-05-20 09:47 CDT | Completed | — |
| 2 | <JIRA_PROJECT_KEY>-NNN | sql-prod-02 | 2026-05-21 02:00 CDT | 2026-05-21 02:31 CDT | Skipped | Prepend skip notice |

Show the datetime values in human-readable CT (not raw ISO offsets). For rows where `MaintStatus = 'Skipped'`, show `"Prepend skip notice"` in the **Description Update** column; show `"—"` for all other rows.

If there are any skipped rows from Step 5, list them separately so the user is aware before approving.

Use the **`AskUserQuestion`** tool to gather the decision — do **not** ask in plain text. Asking via the tool makes the user's answer return as a *tool result* that continues this same skill run, so the orchestrator proceeds to Step 8 instead of treating the reply as a fresh turn and restarting from `read_cmrs_daily`.

Question: **"Apply these N updates?"** — options:
- **Yes — apply all:** apply all at once. Use the exact staged updates file saved in Step 6. If there are multiple files with the same date then select the one with the **highest suffix** — that is the most recent data.
- **Review one by one:** step through each issue and confirm individually (each per-issue confirmation also uses `AskUserQuestion`).
- **Cancel:** stop without making any changes.

Once the answer is received, **proceed directly to Step 8 in this same skill run — do NOT re-invoke `read_cmrs_daily` and do NOT re-run Steps 3–6.**

Do not proceed with any edits without explicit approval.
**In dry-run mode:** render the full preview table and then stop — do **not** call `AskUserQuestion` and do not proceed to Step 8.

---

## Step 8: Apply Jira Edits

Read the selected staged updates file — do not rely on in-memory data from previous step if any. Only process rows where `Status` = `staged`.

For each approved update, call `mcp__atlassian__editJiraIssue`:

- **cloudId:** the constant above
- **issueKey:** the Jira key (e.g., `<JIRA_PROJECT_KEY>-NNN`)
- **fields:** `{"<JIRA_CF_PLANNED_END>": "<new ISO 8601 value>"}`

**Additional step for `MaintStatus = 'Skipped'` rows only:**

Before editing a Skipped issue, call `mcp__atlassian__getJiraIssue` to retrieve its current `description`. Then include `description` in the same `editJiraIssue` call, prepending the skip notice to the existing text:

```
"This maintenance had been skipped.\n\n" + <current description>
```

Pass both `<JIRA_CF_PLANNED_END>` and `description` together in the single `editJiraIssue` call. Do **not** modify the description for any row where `MaintStatus` is not `'Skipped'`.

For each edit:
- Log the issue key, old value, and new value applied.
- For Skipped rows, also log that the description was updated.
- If the edit **succeeds:** log success.
- If the edit **fails:** log the full error (including the payload attempted), notify the user, and continue with the remaining updates — do not halt the batch.

After all edits are attempted, print a summary:
- Issues updated successfully: count + keys (note which also had description updated)
- Issues failed: count + which keys + error reasons
- Issues skipped (no match): count + affected systems values

---

## Anti-patterns to Avoid

- **Run `read_cmrs_daily` first.** If no CSV exists for the window, Step 4 stops gracefully — don't proceed without it.
- **Do not halt the run on a single unmatched row.** Log and skip; partial updates beat none.
- **Do not re-trigger `read_cmrs_daily`/`update_cmrs_daily` after the preview is approved.** The Step 6 staged file is the single source of truth for what gets applied.
- **Do not use the CSV's `<JIRA_CF_PLANNED_END>` as the update source.** That's the originally-scheduled end; the actual end comes from the SQL result (Step 5).
- **Do not run the script with stale dates.** Verify `--start-date`/`--end-date` match the computed 2-day window.
- **Do not apply edits without explicit approval.** The Step 7 preview confirmation is non-negotiable before any `editJiraIssue` call (CMRs are change-management-visible).
- **Do not hardcode absolute Windows paths.** All paths are relative to the project root.
- **Do not stage on a seconds-only difference.** Compare `Planned End` only to the minute (`YYYY-MM-DDTHH:MM`); a mismatch in seconds is not a real change. Staged values are written at minute precision (seconds = `00`).
- **Do not match on Summary instead of Affected Systems.** Summary text can differ between SQL and Jira; `Affected Systems` (`<JIRA_CF_AFFECTED_SYSTEMS>`) is the canonical match key.
- **Do not update the description for non-Skipped rows.** The skip-notice prepend is strictly conditional on `MaintStatus = 'Skipped'`.
