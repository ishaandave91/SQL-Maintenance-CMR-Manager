---
name: update_assignees
description: >
  Clear the assignee (set to unassigned) on the <JIRA_CHANGE_TYPE_LABEL> CMR tickets that
  were just created by create_cmrs in the <JIRA_INSTANCE_URL> Jira instance. Jira's
  backend automation auto-assigns each newly created CMR to the account that created
  it; because these CMRs are for SQL-controlled automated maintenance, they must
  stay unassigned until a dedicated SQL login mapped account exists. Queries all future-dated
  <JIRA_CHANGE_TYPE_LABEL> CMRs (Planned Start today or later) that have an assignee, previews
  them, then sets assignee to null after confirmation. Runs on any day. Use this skill
  whenever the user asks to unassign, clear the assignee on, or reset ownership of
  upcoming CMRs.
compatibility:
  tools:
    - atlassian
  allowed-tools:
    - mcp__atlassian__searchJiraIssuesUsingJql
    - mcp__atlassian__getJiraIssue
    - mcp__atlassian__editJiraIssue
    - mcp__atlassian__atlassianUserInfo
---

# /update_assignees — Unassign Upcoming <JIRA_CHANGE_TYPE_LABEL> CMRs

When `create_cmrs` files a new CMR, Jira's backend automation assigns the issue to the
account that created it. These CMRs are for **SQL-controlled automated maintenance**,
so there is no human owner — they must remain **unassigned** until a dedicated SQL login mapped
account is provisioned. This skill finds all **future-dated** <JIRA_CHANGE_TYPE_LABEL> CMRs
(Planned Start today or later) that still carry an assignee and clears the `assignee`
field (sets it to `null`).

This skill runs on **any day** and is the **last step** in the orchestrator. The backend
auto-assignment is not instantaneous — keeping this last means the time gap created by
the intervening steps lets the auto-assignment settle, so this skill reliably catches and
clears it. The `assignee IS NOT EMPTY` filter makes the skill idempotent — re-running it
when nothing is assigned simply clears nothing.

---

## Constants (this Jira instance)

- **cloudId:** `<JIRA_CLOUD_ID>`
- **Base URL:** https://<JIRA_INSTANCE_URL>
- **project key: `<JIRA_PROJECT_KEY>`
- **Issue type:** `CMR`
- **Change Type filter:** `<JIRA_CHANGE_TYPE_LABEL>`

### Field ID reference

| Field ID | Name |
|---|---|
| `<JIRA_CF_CHANGE_TYPE>` | Change Type |
| `<JIRA_CF_PLANNED_START>` | Planned Start Date/Time |
| `assignee` | Assignee — the field being cleared |

> **JQL note:** Always use `cf[<JIRA_CF_PLANNED_START_ID>]` (or `<JIRA_CF_PLANNED_START>`) for date filtering — this
> instance does not support the named form `"Planned Start Date"` in JQL and returns zero
> results if used.

---

## Environment Defaults

- **Timezone:** `America/Chicago`. DST-aware: CDT (UTC-5) mid-March through early November, CST (UTC-6) the rest of the year.
- **Week starts on:** Monday.

---

## Step 1: Determine Today's Date

This skill runs on **any day** — there is no day-of-week gate. Determine today's date for
use in the JQL filter and the log/CSV filenames.

Execute the below PowerShell command to capture the date, **do not calculate yourself**-

```powershell
# Fetch today's date (Format "yyyy-MM-dd") using powershell command to avoid any miscalculation
Get-Date -Format "yyyy-MM-dd"
```

Capture `today` in `YYYY-MM-DD` format — you will use it in the JQL and the log/CSV filenames.

---

## Step 2: Initialize Log File

Create the log file before any API calls so every operation — including early failures — is captured.

- **Log directory (relative):** `.claude/skills/update_assignees/logs/`
- **Log filename:** `YYYY-MM-DD_HH-MM-SS.log` (timestamp at run start)

Log: run start, today's date, the JQL used, the count of issues returned, and each subsequent operation as it happens.

---

## Step 3: Find Future-Dated <JIRA_CHANGE_TYPE_LABEL> CMRs That Have an Assignee

Use `mcp__atlassian__searchJiraIssuesUsingJql` with the following JQL:

```jql
project = <JIRA_PROJECT_KEY>
  AND "Change Type" = "<JIRA_CHANGE_TYPE_LABEL>"
  AND cf[<JIRA_CF_PLANNED_START_ID>] >= "{today} 00:00"
  AND assignee IS NOT EMPTY
ORDER BY cf[<JIRA_CF_PLANNED_START_ID>] ASC
```

Replace `{today}` with the date from Step 1 (e.g. `"2026-06-07 00:00"`). Always use
`cf[<JIRA_CF_PLANNED_START_ID>]` (Planned Start), never the named form `"Planned Start Date"` — the named
form returns zero results on this instance.

**Request only these fields** (everything the Step 4 preview needs — do not request `reporter`; it is never displayed):

```
summary, created, assignee, <JIRA_CF_PLANNED_START>
```

This returns every <JIRA_CHANGE_TYPE_LABEL> CMR whose Planned Start is **today or later** that
currently carries an assignee — exactly the upcoming issues that must be unassigned. The
`cf[<JIRA_CF_PLANNED_START_ID>] >= today` bound deliberately excludes already-run / closed CMRs that may have
an intentional owner. Issues already unassigned are excluded by `assignee IS NOT EMPTY`,
so re-running this skill is safe and idempotent.

Log the number of records returned. If the API call fails, log the full error and stop.

**If zero rows are returned:** log that nothing needs clearing (no future-dated CMR is
currently assigned — either none were created, or the backend has not assigned yet, or
they are already unassigned), notify the user, and stop.

---

## Step 4: Preview the Issues to Be Unassigned and Confirm

Show a full preview table of every issue that would be unassigned — one row per issue —
before any Jira API calls:

| # | Key | Summary | Current Assignee | Planned Start (CT) | Created (CT) | New Assignee |
|---|-----|---------|------------------|--------------------|--------------|--------------|
| 1 | <JIRA_PROJECT_KEY>-NNN | ... | <AUTHOR_NAME> | 2026-06-08 08:00 CDT | 2026-06-07 02:05 CDT | Unassigned |
| 2 | <JIRA_PROJECT_KEY>-NNN | ... | <AUTHOR_NAME> | 2026-06-08 09:00 CDT | 2026-06-07 02:05 CDT | Unassigned |

Render the datetime values in human-readable CT (not raw ISO offsets).

Use the **`AskUserQuestion`** tool to gather the decision — do **not** ask in plain text.
Asking via the tool makes the user's answer return as a *tool result* that continues this
same skill run, so the workflow proceeds to Step 5 instead of treating the reply as a
fresh turn and restarting earlier steps.

Question: **"Unassign these N CMR issues?"** — options:
- **Yes — unassign all:** clear the assignee on all listed issues (proceed to Step 5).
- **Review one by one:** step through each issue and confirm individually (each per-issue confirmation also uses `AskUserQuestion`).
- **Cancel:** stop without changing anything.

- If cancelled, log the cancellation and stop.
- Do **not** proceed to clearing without explicit confirmation.
- **In dry-run mode:** render the full preview table and then stop — do **not** call `AskUserQuestion` and do not proceed to Step 5.

---

## Step 5: Clear the Assignee on Each Issue

For each confirmed issue, call `mcp__atlassian__editJiraIssue`:

- **cloudId:** the constant above
- **issueKey:** the Jira key (e.g., `<JIRA_PROJECT_KEY>-NNN`)
- **fields:** `{"assignee": null}`

Setting `assignee` to `null` removes the auto-assigned owner and leaves the issue unassigned.

For each edit, write to the **log file**: the issue key, the previous assignee (from Step 3), and that it was cleared to unassigned (or the full error on failure). Do **not** echo each issue to the user mid-loop — defer to the single summary below. On a failure, continue with the remaining issues — do not halt the batch.

After all edits are attempted, print **one consolidated summary** to the user:
- Issues unassigned successfully: count + keys
- Issues failed: count + which keys + error reasons

---

## Step 6: Save an Audit CSV (optional but preferred)

Write a small CSV recording what was cleared, for audit and troubleshooting.

- **Data directory (relative):** `.claude/skills/update_assignees/data/`
- **Base filename:** `unassigned_{today}.csv` (e.g., `unassigned_2026-06-07.csv`)
- If a file with that base name already exists, append an incrementing suffix (`_1`, `_2`, …) — never overwrite.

**CSV columns (write exactly these headers, in this order):**

| Column | Content |
|---|---|
| `Jira Key` | Jira issue key, e.g. `<JIRA_PROJECT_KEY>-NNN` |
| `Summary` | Issue summary |
| `Previous Assignee` | Display name of the auto-assigned account that was cleared |
| `Planned Start` | ISO 8601 value from `<JIRA_CF_PLANNED_START>` |
| `Result` | `unassigned` for cleared rows; `failed` for rows whose edit errored |
| `Error` | Populated only for failed rows; empty otherwise |

**In dry-run mode:** do not write this CSV — Step 4 already stopped before any changes.

---

## Anti-patterns to Avoid

- **Do not run before the backend auto-assignment has settled.** Keep this as the orchestrator's last step so the time gap after `create_cmrs` lets the backend automation finish — otherwise the JQL may return nothing and the assignment lands afterward unreverted.
- **Do not drop the `cf[<JIRA_CF_PLANNED_START_ID>] >= today` bound.** Filtering on Planned Start today-or-later plus `assignee IS NOT EMPTY` scopes the change to upcoming maintenances only. Never clear assignees on past-dated / closed CMRs that may have an intentional owner.
- **Do not clear issues that are already unassigned.** The `assignee IS NOT EMPTY` filter handles this; never blindly edit every <JIRA_CHANGE_TYPE_LABEL> CMR.
- **Do not skip the preview.** CMRs are visible to the change-management audience. Step 4 confirmation is non-negotiable outside dry-run.
- **Do not halt the entire batch on a single edit failure.** Log and continue — partial success beats losing all remaining clears.
- **Do not hardcode absolute Windows paths.** All paths are relative to the project root.
