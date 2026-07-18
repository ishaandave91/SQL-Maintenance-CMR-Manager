---
name: create_cmrs
description: >
  Create <JIRA_CHANGE_TYPE_LABEL> CMR tickets in bulk in the <JIRA_INSTANCE_URL> Jira
  instance by reading scheduled maintenance data from a SQL Server view. Fetches
  rows whose Planned Start Date falls in the current or next Monday–Sunday window,
  prepares a Jira payload for each row, previews all issues for confirmation, then
  creates them in batch. Use this skill whenever the user asks to create, generate,
  file, or open CMRs for automated maintenances, SQL Maintenance jobs, or the upcoming week's
  change tickets.
compatibility:
  tools:
    - atlassian
  allowed-tools:
    - mcp__atlassian__searchJiraIssuesUsingJql
    - mcp__atlassian__getJiraIssue
    - mcp__atlassian__createJiraIssue
    - mcp__atlassian__createIssueLink
    - mcp__atlassian__getIssueLinkTypes
    - mcp__atlassian__lookupJiraAccountId
    - mcp__atlassian__atlassianUserInfo
---

# /create_cmrs — Batch-Create <JIRA_CHANGE_TYPE_LABEL> CMR Tickets

Reads scheduled maintenance data from a SQL Server view via a local Python script,
builds a Jira payload for each row, previews all issues for user confirmation, and
then creates them in bulk in the **CMR** Jira project.

This skill is scoped exclusively to **automated <JIRA_CHANGE_TYPE_LABEL> jobs**. Do not use
it for ad-hoc or manually-described CMRs — use the general `create-cmr` skill for
those.

---

## Constants (this Jira instance)

- **cloudId:** `<JIRA_CLOUD_ID>`
- **Base URL:** https://<JIRA_INSTANCE_URL>
- **project key: `<JIRA_PROJECT_KEY>`
- **Issue type:** `CMR` (id: `10582`)
- **Fixed component:** `<JIRA_COMPONENT_MAIN>`
- **Fixed change type:** `<JIRA_CHANGE_TYPE_LABEL>`
- **Reporter:** `<JIRA_SERVICE_ACCOUNT_EMAIL>` (accountId: `<JIRA_SERVICE_ACCOUNT_ID>`)

### Field ID Mappings

Use `{"id": "<id>"}` for select-type fields; plain strings for text fields.

#### `<JIRA_CF_CHANGE_TYPE>` — Change Type
| Value | ID |
|-------|----|
| **<JIRA_CHANGE_TYPE_LABEL>** | **`<JIRA_CHANGE_TYPE_OPTION_ID>`** |

#### `<JIRA_CF_LOCATION>` — Location
| Value | ID |
|-------|----|
| Hosted Service | `<JIRA_LOCATION_HOSTED_OPTION_ID>` |
| **<DC_LOCATION_1>** | **`<JIRA_LOCATION_DC1_OPTION_ID>`** |
| **<DC_LOCATION_2>** | **`<JIRA_LOCATION_DC2_OPTION_ID>`** |
| DC-Both | `<JIRA_LOCATION_BOTH_OPTION_ID>` |

#### `components`
| Name | ID |
|------|----|
| **<JIRA_COMPONENT_MAIN>** | **`<JIRA_COMPONENT_MAIN_ID>`** |

### Field Format Notes

- **Datetime fields** (`<JIRA_CF_PLANNED_START>`, `<JIRA_CF_PLANNED_END>`): ISO 8601 with CDT offset — `"2026-05-27T08:00:00.000-0500"`.
- **`assignee`**: Always set to `null` to keep issues unassigned. Jira auto-assigns the API caller if omitted.
- **`reporter`**: Cannot be set via the create screen — restricted by the project screen configuration.
- **`<JIRA_CF_ADDITIONAL_DETAILS>` (Additional Details)**: Must be ADF if used. Sending markdown returns `"Operation value must be an Atlassian Document"`. This skill does not populate this field in the automated flow, but note the constraint if extending the skill.

---

## Environment Defaults

- **Timezone:** `America/Chicago`. DST-aware: CDT (UTC-5) mid-March through early November, CST (UTC-6) the rest of the year.
- **Week starts on:** Monday.

---

## Step 1: Determine the Target Week's Date Range

Calculate the Monday–Sunday span for the **current or next** week:

Execute below powershell command to find today's day

```powershell
# Fetch today's day using powershell command to avoid any miscalculation
(Get-Date).DayOfWeek
```

- If today is **Sunday**, the next week starts tomorrow (Monday).
- Otherwise, the target week is the current week (starting this past Monday).

**Examples:** 
  - If today is 2026-05-26 (Tuesday), week = 2026-05-25 (Mon) to 2026-05-31 (Sun).
  - If today is 2026-05-31 (Sunday), week = 2026-06-01 (Mon) to 2026-06-07 (Sun).

Capture `week_start_date` and `week_end_date` in `YYYY-MM-DD` format.

> This skill may run on **any day** — the day only selects the target week (Sunday → next Mon–Sun, otherwise current Mon–Sun). Duplicate creation is prevented per-row against Jira in Step 4.5, not by the day of week.

---

## Step 2: Fetch Data from SQL Server

Run the Python script to pull maintenance rows for the target date range:

```
py .claude\skills\create_cmrs\scripts\fetchCMRsForNextWeek.py --start-date {week_start_date} --end-date {week_end_date_exclusive}
```

Where:
- `--start-date` = `week_start_date` from Step 1 (e.g. `2026-05-25`) — inclusive lower bound.
- `--end-date` = `week_end_date` + 1 day (e.g. `2026-06-01`) — the SQL filter uses an exclusive upper bound, so add one day to include the full Sunday.

**Example for current week 2026-05-25 to 2026-05-31:**
```
py .claude\skills\create_cmrs\scripts\fetchCMRsForNextWeek.py --start-date 2026-05-25 --end-date 2026-06-01
```

The script emits the rows as **CSV on stdout** (the row count prints separately on stderr), so capture stdout and save it directly — no reformatting needed.

Save the result to a new CSV file:

- **Data directory (relative):** `.claude/skills/create_cmrs/data/`
- **Filename:** `{week_start_date}_to_{week_end_date}.csv`

**If a file with that name already exists:** stop immediately and notify the user. Running again would risk creating duplicate Jira issues for the same week.

**If the script returns zero rows:** create the CSV with only the header row, log this outcome, and stop — there is nothing to create.

If the script fails with an error, log the full error and stop.

---

## Step 3: Initialize Log File

Create the log file after a successful data fetch so its existence confirms the fetch succeeded.

- **Log directory (relative):** `.claude/skills/create_cmrs/logs/`
- **Log filename:** `YYYY-MM-DD_HH-MM-SS.log` (timestamp at run start)

Log: run start, target date range, CSV path, row count fetched, and each subsequent operation as it happens.

---

## Step 4: Prepare Jira Payloads

Read the CSV from Step 2. If running in dry-run mode (CSV was not saved to disk), use the data returned directly from the script output in Step 2 — do not stop or report an error because the file is absent. For each row, construct a payload:

| Jira Field | Source | Notes |
|---|---|---|
| `project` | constant | `CMR` |
| `issuetype` | constant | `CMR` (id `10582`) |
| `reporter` | constant | see Constants |
| `assignee` | constant | `null` — always |
| `summary` | CSV column `Subject` | |
| `description` | CSV column `Description` | markdown is fine for this field |
| `components` | constant | `[{"id": "<JIRA_COMPONENT_MAIN_ID>"}]` (<JIRA_COMPONENT_MAIN>) |
| `<JIRA_CF_PLANNED_START>` | CSV column `PlannedStartDateTime` | ISO 8601 CDT, e.g. `"2026-05-27T08:00:00.000-0500"` |
| `<JIRA_CF_PLANNED_END>` | CSV column `PlannedEndDateTime` | same format |
| `<JIRA_CF_AFFECTED_SYSTEMS>` | CSV column `AffectedServers` | plain text |
| `<JIRA_CF_LOCATION>` | CSV column `DataCenterLocation` | pass as `{"id": "<id>"}` — see ID Mappings |
| `<JIRA_CF_CHANGE_TYPE>` | constant | `{"id": "<JIRA_CHANGE_TYPE_OPTION_ID>"}` (<JIRA_CHANGE_TYPE_LABEL>) |
| `duedate` | derived | date portion of `PlannedStartDateTime`, format `"YYYY-MM-DD"` |

If any value is missing, undefined, or ambiguous for a row, **pause and ask the user** before proceeding. Never silently skip a row or substitute a guess.

---

## Step 4.5: Duplicate Detection Against Jira

This is the authoritative duplicate guard. The Step 2 CSV-file check is the first layer; this per-row check against Jira is the second. Run it **on every run, including dry-run** (the query is read-only). It compares each candidate payload built in Step 4 against the CMRs that already exist in Jira for the target week, and removes any candidate that already exists so it is never created twice.

### Query existing CMRs in the target week

Use `mcp__atlassian__searchJiraIssuesUsingJql` with:

```jql
project = <JIRA_PROJECT_KEY>
  AND "Change Type" = "<JIRA_CHANGE_TYPE_LABEL>"
  AND cf[<JIRA_CF_PLANNED_START_ID>] >= "{week_start_date} 00:00"
  AND cf[<JIRA_CF_PLANNED_START_ID>] <= "{week_end_date} 23:59"
ORDER BY cf[<JIRA_CF_PLANNED_START_ID>] ASC
```

- `{week_start_date}` / `{week_end_date}` = the **inclusive** human Monday/Sunday from Step 1 (NOT the exclusive `+1 day` SQL bound used in Step 2).
- Always use `cf[<JIRA_CF_PLANNED_START_ID>]`, never the named form `"Planned Start Date"` (returns zero results on this instance).
- **Request fields:** `summary, <JIRA_CF_AFFECTED_SYSTEMS>, <JIRA_CF_PLANNED_START>` (plus the issue key). `summary` is used only for the material-mismatch check; do not request `status` or other fields — dedup needs nothing more.
- **Paginate to completion** — fetch every page before building the lookup set; a duplicate hiding on an unfetched page would slip through.
- **On API failure: log the full error and STOP the batch (fail closed).** Never proceed to creation if the dedup query could not complete — failing open risks duplicates.

### Build the existing-issues lookup set

For each fetched issue, compute a composite key and add it to a set `existing_keys`:

```
key = normalize_systems(<JIRA_CF_AFFECTED_SYSTEMS>) + "|" + normalize_start(<JIRA_CF_PLANNED_START>)
```

Apply the **same two normalization functions** to both the fetched Jira issues and the candidate payloads — the comparison must be symmetric or matches will be missed.

**`normalize_systems(text)`** — neutralizes ordering/spacing/case differences in the Affected Systems list (it can be a comma-joined `STRING_AGG`):
1. If empty/null, do **not** key on it — flag the row for the Step 4 "missing/ambiguous → pause and ask the user" rule.
2. Split on comma.
3. For each token: trim, collapse internal whitespace runs to a single space, lowercase. Drop empty tokens (handles trailing/double commas).
4. **Sort** the tokens (case-insensitive) — so `SQL-01, SQL-02` and `SQL-02,SQL-01` produce the same key.
5. Re-join with a single `,`.

**`normalize_start(value)`** — compares on the **local wall-clock minute**, never UTC:
- SQL/CSV side `2026-05-27 08:00:00` → `2026-05-27T08:00`.
- Jira `<JIRA_CF_PLANNED_START>` `2026-05-27T08:00:00.000-0500` → take the part **before** the offset → `2026-05-27T08:00`.
- Emit canonical `YYYY-MM-DDTHH:MM`. Do **not** convert to UTC — the wall-clock time is invariant across the SQL→Jira offset conversion even across a DST boundary (CDT −0500 ↔ CST −0600), whereas a UTC comparison would shift the hour when the offset flips and cause false misses.

### Classify each candidate

For each candidate payload from Step 4, compute its key with the same functions:
- **key is in `existing_keys`** → **SKIPPED-as-duplicate**. Record the matched existing Jira key. Do not create it.
- **key is not in `existing_keys`** → **NEW**. It proceeds to Steps 5–6.

### Guard against false-positive skips (the dangerous case)

The composite key is a **heuristic, not a unique constraint** — there is no unique maintenance ID flowing into Jira. So a skip can be *wrong* (two genuinely different maintenances on the same servers in the same minute). A wrong skip silently drops a real CMR, which is worse than a missed duplicate. Therefore:

- **Never skip silently.** Every skipped row must appear in the Step 5 preview (Section B) with its matched Jira key, and be logged with **both** keys (candidate + existing).
- **If the same composite key appears twice within the candidate set itself** (two CSV rows collide), do **not** auto-dedup them against each other — flag the collision, list both rows, and **pause via `AskUserQuestion`** (same as the Step 4 "ambiguous → pause and ask" rule).
- **If a candidate matches an existing Jira issue but the summaries differ materially**, surface it and pause rather than silently skipping.

Log the counts: total candidates, NEW, SKIPPED-as-duplicate (with key pairs).

---

## Step 5: Preview All Issues and Confirm

Show two sections before any Jira API calls, using the NEW / SKIPPED classification from Step 4.5.

**Section A — Will be created (N new):** one row per NEW payload.

| # | Summary | Location | Affected Systems | Planned Start (CT) | Planned End (CT) | Due Date | Component | Change Type |
|---|---------|----------|------------------|--------------------|------------------|----------|-----------|-------------|
| 1 | ... | <DC_LOCATION_1> | ... | 2026-05-27 08:00 CDT | 2026-05-27 09:30 CDT | 2026-05-27 | <JIRA_COMPONENT_MAIN> | <JIRA_CHANGE_TYPE_LABEL> |
| 2 | ... | <DC_LOCATION_2> | ... | ... | ... | ... | <JIRA_COMPONENT_MAIN> | <JIRA_CHANGE_TYPE_LABEL> |

**Section B — Skipped as duplicates (M):** one row per candidate that already exists in Jira, so the user can verify nothing real was dropped.

| # | Summary | Affected Systems | Planned Start (CT) | Existing Jira Key |
|---|---------|------------------|--------------------|--------------------|
| 1 | ... | ... | 2026-05-27 08:00 CDT | [<JIRA_PROJECT_KEY>-NNN](https://<JIRA_INSTANCE_URL>/browse/<JIRA_PROJECT_KEY>-NNN) |

Render the datetime values in human-readable CT for the preview (not raw ISO offsets), so the user can quickly spot timezone errors.

Use the **`AskUserQuestion`** tool to gather the decision — do **not** ask in plain text. Asking via the tool makes the user's answer return as a *tool result* that continues this same skill run, so the workflow proceeds to Step 6 instead of treating the reply as a fresh turn and restarting earlier steps.

Question: **"Create the N new CMR issues? (M duplicates will be skipped.)"** — options:
- **Yes — create all:** create all NEW issues in batch (proceed to Step 6).
- **Edit a specific row:** identify a row by number and re-enter the field(s).
- **Cancel:** stop without creating anything.

- If the user picks **Edit a specific row**, let them identify it by number and re-enter the field(s). Re-render the preview and ask again via `AskUserQuestion`.
- If cancelled, log the cancellation and stop.
- Do **not** proceed to creation without explicit confirmation.
- **If N = 0** (every candidate already exists): render Section B, state that everything already exists, and stop — do **not** call `AskUserQuestion` and do not proceed to Step 6.
- **In dry-run mode:** render both sections (would-create + would-skip) and then stop — do **not** call `AskUserQuestion` and do not proceed to Step 6.

---

## Step 6: Create Jira Issues

Call `mcp__atlassian__createJiraIssue` for each **NEW** payload (from Step 4.5) in order. Never create a SKIPPED-as-duplicate row.

For each issue created, write the returned key and URL (`https://<JIRA_INSTANCE_URL>/browse/<KEY>`) to the **log file**. Do **not** echo each issue to the user mid-loop — defer to the single summary below so output stays compact.

If a single issue creation fails, log the full error (including the payload) and continue with the remaining rows. Do not halt the entire batch on one failure.

After all rows are processed, print **one consolidated summary** to the user:
- Issues created successfully: count + keys (with URLs)
- Issues failed: count + which rows (by summary or row number) + error reasons

---

## Anti-patterns to Avoid

- **Do not run if the CSV already exists for the target week.** The duplicate-file check in Step 2 is the first guard against double-creating issues. If the file is there, stop and investigate before proceeding.
- **Do not skip the Jira duplicate check (Step 4.5).** It is the authoritative, second-layer guard and runs on every run including dry-run. If its query fails, fail closed — stop, do not create.
- **Do not treat the composite key as a unique constraint.** Affected Systems + Planned Start is a heuristic; there is no unique maintenance ID in Jira. Because a wrong skip silently drops a real CMR, never skip silently — every skip appears in Section B of the preview with its matched Jira key and is logged with both keys, and within-batch key collisions or material summary mismatches pause via `AskUserQuestion`.
- **Do not skip the preview.** CMRs are visible to the change-management audience. Step 5 is non-negotiable.
- **Do not send markdown in `<JIRA_CF_ADDITIONAL_DETAILS>` (Additional Details).** That field requires ADF. This skill does not use it in the automated flow, but log a warning if a future caller tries to pass markdown there.
- **Do not omit `assignee: null`.** Jira auto-assigns the API caller, which then requires a separate edit call to clear.
- **Do not run the Python script with stale dates.** Always verify `start_date` / `end_date` in the script match the computed week before executing.
- **Do not halt the entire batch on a single creation failure.** Log and continue — partial success is better than losing all remaining rows.
- **Do not confirm per-issue in batch mode.** A single batch confirmation (Step 5) covers all rows. Per-issue prompting in a 20-row batch is unusable.
