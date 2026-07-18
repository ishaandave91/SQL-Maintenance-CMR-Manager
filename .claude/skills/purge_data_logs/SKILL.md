---
name: purge_data_logs
description: >
  Purge CSV and log files older than 14 days from the data/ and logs/ directories
  of the four CMR skill folders: create_cmrs, read_cmrs_daily, update_assignees,
  and update_cmrs_daily. Extracts the reference date from each filename using the
  project's YYYY-MM-DD naming convention, identifies files whose date falls before
  the 14-day cutoff, previews the candidates, then removes them via PowerShell
  Remove-Item. Also prunes individual log entries older than 365 days from inside
  the two hook audit logs (jira_mcp_audit.log and py_usage.log) without deleting the
  files themselves. In dry-run mode, shows what would be deleted or pruned without
  changing anything. Always runs as the last step in the orchestrator so cleanup
  never interferes with the Jira management steps that precede it. Use this skill
  whenever the user asks to clean up, purge, or remove old data or log files from the
  skill directories, or stale entries from the hook audit logs.
compatibility:
  allowed-tools:
    - PowerShell
    - Write
---

# /purge_data_logs — Purge Old CSV and Log Files from Skill Directories

Scans the `data/` and `logs/` subdirectories of all four CMR skill folders, extracts the
reference date embedded in each filename, and removes any file whose date is **14 or more
days before today**. This skill is always the **last step** in the orchestrator so that
cleanup never interferes with the Jira management tasks that precede it.

File deletion is performed exclusively via PowerShell `Remove-Item`. The Bash `rm` command
and `-rf` flags are never used.

This skill has **two distinct jobs**:
1. **File-level purge (Steps 3–5)** — delete whole CSV/log files older than **14 days** from the skill `data/` and `logs/` directories.
2. **Entry-level pruning (Step 6)** — remove log *lines* older than **365 days** from inside the two hook audit logs, **keeping the files in place**. The two jobs use different cutoffs and different mechanisms; do not conflate them.

---

## Target Directories

| Skill | Data directory | Logs directory |
|---|---|---|
| `create_cmrs` | `.claude/skills/create_cmrs/data/` | `.claude/skills/create_cmrs/logs/` |
| `read_cmrs_daily` | `.claude/skills/read_cmrs_daily/data/` | `.claude/skills/read_cmrs_daily/logs/` |
| `update_cmrs_daily` | `.claude/skills/update_cmrs_daily/data/` | `.claude/skills/update_cmrs_daily/logs/` |
| `update_assignees` | `.claude/skills/update_assignees/data/` | `.claude/skills/update_assignees/logs/` |
| `purge_data_logs` | `.claude/skills/purge_data_logs/data/` | `.claude/skills/purge_data_logs/logs/` |

---

## File Naming Conventions and Date Extraction

The project naming conventions that carry a recognizable date:

| Pattern | Example | Extracted date |
|---|---|---|
| `YYYY-MM-DD.csv` | `2026-05-27.csv` | `2026-05-27` |
| `YYYY-MM-DD_N.csv` | `2026-06-01_1.csv` | `2026-06-01` |
| `YYYY-MM-DD_to_YYYY-MM-DD.csv` | `2026-05-25_to_2026-05-31.csv` | `2026-05-25` |
| `staged_updates_YYYY-MM-DD.csv` | `staged_updates_2026-06-02.csv` | `2026-06-02` |
| `unassigned_YYYY-MM-DD.csv` | `unassigned_2026-06-07.csv` | `2026-06-07` |
| `YYYY-MM-DD_HH-MM-SS.log` | `2026-05-28_12-01-57.log` | `2026-05-28` |
| `YYYY-MM-DD_apply_staged_YYYY-MM-DD.log` | `2026-06-04_apply_staged_2026-06-03.log` | `2026-06-04` |

**Date extraction rule:** locate the first substring matching `\d{4}-\d{2}-\d{2}` (four-digit
year, two-digit month, two-digit day, hyphen-separated) in the filename. That value is the
file's reference date. Any file whose name contains no such pattern is classified as
**SKIPPED (unrecognized name)** — log it and do not touch it.

---

## Step 1: Determine Today's Date and the Cutoff Date

Execute the following PowerShell commands — do not calculate dates manually:

```powershell
# Fetch today's date to avoid any miscalculation
Get-Date -Format "yyyy-MM-dd"
```

```powershell
# Compute the file cutoff date; files dated strictly before this are purge-eligible
(Get-Date).AddDays(-14).ToString("yyyy-MM-dd")
```

```powershell
# Compute the hook-log entry cutoff; log lines dated strictly before this are pruned (Step 6)
(Get-Date).AddDays(-365).ToString("yyyy-MM-dd")
```

Capture all three values:
- `today` — used in the log filename and the final summary.
- `cutoff_date` — any **file** whose extracted date is **strictly before** this value is purge-eligible (Steps 3–5).
- `cutoff_date_logs` — any **log entry** dated **strictly before** this value is pruned from the hook audit logs (Step 6).

---

## Step 2: Initialize Log File

Ensure the log directory exists, then create the log file before scanning so every
operation — including early failures — is captured.

```powershell
# Create the logs directory if it does not exist
New-Item -ItemType Directory -Force -Path ".claude\skills\purge_data_logs\logs" | Out-Null
```

- **Log directory (relative):** `.claude/skills/purge_data_logs/logs/`
- **Log filename:** `YYYY-MM-DD_HH-MM-SS.log` (timestamp at run start, matching the project log convention)

Log: run start, today's date, cutoff date, the eight directories being scanned.

---

## Step 3: Scan All Directories and Classify Files

For each of the eight target directories, list the relevant files:

```powershell
# List CSV files in a data/ directory
Get-ChildItem -Path ".claude\skills\create_cmrs\data" -File -Filter "*.csv" -ErrorAction SilentlyContinue

# List log files in a logs/ directory
Get-ChildItem -Path ".claude\skills\create_cmrs\logs" -File -Filter "*.log" -ErrorAction SilentlyContinue
```

Repeat for each of the ten target directories (five `data/` for `*.csv`, five `logs/` for
`*.log`). Do not recurse into subdirectories.

For each file found, apply the date extraction rule:

1. Search the filename for the first `YYYY-MM-DD` substring using the regex `\d{4}-\d{2}-\d{2}`.
2. If no date pattern is found → **SKIPPED (unrecognized name)**. Log the filename. Do not delete.
3. Parse the extracted date string.
4. If `file_date < cutoff_date` → **PURGE-ELIGIBLE**.
5. Otherwise → **RETAINED**.

After scanning all eight directories, tally the counts for each classification.

---

## Step 4: Preview All Purge-Eligible Files

Print a structured preview of every file classified as PURGE-ELIGIBLE, grouped by skill
directory, before any deletion occurs.

**Files to be deleted — N total (reference date before `{cutoff_date}`):**

| # | Skill | Type | Filename | File Date | Age (days) |
|---|-------|------|----------|-----------|-----------|
| 1 | create_cmrs | data | 2026-05-25_to_2026-05-31.csv | 2026-05-25 | 13 |
| 2 | read_cmrs_daily | logs | 2026-05-28_12-01-57.log | 2026-05-28 | 10 |

Also display:
- **Retained:** count of files too recent to purge.
- **Skipped (unrecognized name):** count and list of filenames that had no parseable date.

**In dry-run mode:** render the full preview table and then stop — do not proceed to Step 5.
Print: `[DRY-RUN] The above N files would be deleted in live mode — no changes were made.`

**If zero files are PURGE-ELIGIBLE:** log and notify the user that nothing qualifies for
purging, and stop.

---

## Step 5: Delete Purge-Eligible Files

No user confirmation is required — this step executes automatically after the Step 4
preview. For each PURGE-ELIGIBLE file, delete using PowerShell `Remove-Item`:

```powershell
Remove-Item -Path "<relative_path_to_file>" -Force
```

**Never use `rm`, `rm -rf`, or any Bash deletion command.** Use only PowerShell `Remove-Item`.

After each attempt, write to the log file:
- On success: `DELETED: <relative path>`
- On failure: `FAILED: <relative path> — <error message>`

On a failure, log the error and continue with the remaining files — do not halt the batch.

After all deletions are attempted, print one consolidated summary to the user:
- **Deleted successfully:** count + filenames
- **Failed:** count + filenames + error reasons
- **Retained (too recent):** count
- **Skipped (unrecognized name):** count + filenames

---

## Step 6: Prune Old Entries from the Hook Audit Logs

This step edits the **contents** of two hook audit logs — it removes log lines older than
`cutoff_date_logs` (365 days) but **never deletes the files themselves**.

| File | Entry format (one log line per entry) |
|---|---|
| `.claude/hooks/logs/jira_mcp_audit.log` | `YYYY-MM-DD HH:MM:SS | …` |
| `.claude/hooks/logs/py_usage.log` | `YYYY-MM-DD HH:MM:SS | …` |

**Pruning rule:** each line begins with a `YYYY-MM-DD` date. Remove every line whose date is
**strictly before** `cutoff_date_logs`. Retain all other lines, in their original order. A
line that does **not** begin with a parseable `YYYY-MM-DD` is **always retained** (never drop
a line you cannot date — it may be a wrapped/continuation entry).

Run the following single PowerShell block. Set `$dryRun = $true` in dry-run mode and
`$dryRun = $false` in live mode. It reads each file, counts, and — only in live mode and only
when there is something to remove — rewrites the file in place (UTF-8, no BOM, original line
order preserved):

```powershell
$dryRun = $true   # set to $false in live mode
$cutoff = (Get-Date).AddDays(-365).Date
foreach ($path in @(".claude\hooks\logs\jira_mcp_audit.log", ".claude\hooks\logs\py_usage.log")) {
    if (-not (Test-Path -LiteralPath $path)) { "MISSING: $path"; continue }
    $lines = @(Get-Content -LiteralPath $path)
    $kept = [System.Collections.Generic.List[string]]::new()
    $removed = 0; $unparsed = 0
    foreach ($line in $lines) {
        if ($line -match '^\s*(\d{4}-\d{2}-\d{2})') {
            if ([datetime]::ParseExact($matches[1], "yyyy-MM-dd", $null) -lt $cutoff) { $removed++ }
            else { $kept.Add($line) }
        } else { $kept.Add($line); $unparsed++ }
    }
    if (-not $dryRun -and $removed -gt 0) {
        [System.IO.File]::WriteAllLines((Resolve-Path -LiteralPath $path).Path, $kept)
        "PRUNED: $path | removed=$removed retained=$($kept.Count) unparsed_retained=$unparsed"
    } else {
        "$(if($dryRun){'[DRY-RUN] '})$path | total=$($lines.Count) would_remove=$removed retain=$($kept.Count) unparsed_retained=$unparsed"
    }
}
```

- **In dry-run mode:** the block only reports `would_remove` counts and makes no changes. Print the per-file counts; do not rewrite anything.
- **If `removed = 0` for a file:** leave that file untouched (no rewrite — preserves its timestamp).
- **In live mode with `removed > 0`:** the file is rewritten with the retained lines only.

Log each file's `total / removed / retained / unparsed_retained` counts. If a file is missing,
log `MISSING` and continue — do not treat it as an error.

After this step, append to the consolidated summary:
- **Hook logs pruned:** per file — entries removed + entries retained.

---

## Anti-patterns to Avoid

- **Never use `rm`, `rm -rf`, or Bash deletion commands.** Use only PowerShell `Remove-Item`.
- **Never delete a file without first extracting and validating a date from its name.** If no `YYYY-MM-DD` pattern is found, classify the file as SKIPPED and leave it alone.
- **Never delete files from directories outside the eight target directories.** Do not recurse into subdirectories of `data/` or `logs/`.
- **Never run before `update_assignees`.** This skill must always be the final step in the orchestrator — cleanup must not interrupt any Jira management task.
- **Never delete `SKILL.md`, `scripts/`, or any file outside `data/` and `logs/`.** The scan is scoped exclusively to those two subdirectories per skill.
- **In dry-run mode:** stop after the preview — do not delete any file, and do not rewrite either hook log in Step 6.
- **Do not skip the preview.** Step 4 is non-negotiable — the user must see exactly what will be deleted before Step 5 executes.
- **Never delete the hook audit log files themselves.** Step 6 prunes entries *in place* only — the two `.claude/hooks/logs/*.log` files must always continue to exist (even if pruned to empty).
- **Never drop a log line that has no parseable leading `YYYY-MM-DD`.** Such lines are always retained — losing un-dated lines risks corrupting an entry that wrapped across lines.
- **Only the two named hook logs are in scope for entry pruning.** Do not entry-prune any other file, and do not file-delete the hook logs in Steps 3–5 (the file-deletion scan never touches `.claude/hooks/logs/`).
