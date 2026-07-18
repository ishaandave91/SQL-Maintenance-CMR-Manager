## Background

SQL maintenance schedules generate dozens of Jira change tickets 
every week — created, updated, and closed by automation, with no 
human filing them. Managing that volume manually was error-prone 
and time-consuming. This pipeline replaces that manual work with 
an AI agent that handles the full CMR lifecycle end-to-end, 
inside Claude Code.

---

# SQL Maintenance CMR Manager

![Claude Code](https://img.shields.io/badge/Claude_Code-Native-black)
![MCP](https://img.shields.io/badge/MCP-Atlassian-blue)
![Python](https://img.shields.io/badge/Python-Helper_Scripts-yellow)
![Status](https://img.shields.io/badge/Status-Production-brightgreen)

An automation pipeline that keeps Jira **CMR (Change Management Request)** tickets in sync with **SQL scheduled maintenances**. It reads scheduled-maintenance data from an internal database, files the matching CMR tickets in Jira, writes the actual completion times back once maintenances finish, keeps automated changes unassigned, and tidies up its own working files. This project is **Claude Code–native**: there is no standalone application or server to deploy. Every action is performed by an orchestrator agent, a set of Claude *skills*, and Model Context Protocol (MCP) tool calls, with governance hooks enforcing project rules. You operate it entirely from within Claude Code.

> This document describes **what the project does and how to run it**. 

---

## What it does

For each in-scope automated maintenance, the pipeline keeps a Jira CMR ticket accurate end-to-end:

1. **Create** — files a CMR for every maintenance scheduled in the target Monday–Sunday week.
2. **Read back** — pulls the recently filed CMRs from Jira into local working files.
3. **Update** — patches each CMR's *Planned End* with the **actual** completion time once the maintenance finishes, and flags any maintenance that was skipped.
4. **Unassign** — clears the owner that Jira's backend auto-assigns, so automated changes stay ownerless.
5. **Purge** — deletes its own aged working files so the workspace stays lean.

The sequence is safe to run **any day**: it never creates duplicate CMRs (it checks Jira first), and re-running an update is a no-op when nothing has changed.

---

## How it works

| Piece | Role |
|---|---|
| **Orchestrator agent** | Runs the whole pipeline in order, previewing each step; supports a live mode and a no-writes dry-run mode. |
| **Skills** | Five focused, self-contained units — one per stage of the pipeline (below). |
| **MCP (Atlassian)** | All Jira reads and writes go through the Atlassian MCP server. |
| **Helper scripts** | Two small scripts fetch maintenance data from the internal database. |
| **Governance hooks** | Enforce project rules (e.g. the mandated Python launcher) and record an audit trail of Jira calls. |

## Component map

```
                        ┌──────────────────────────────────────────┐
                        │            Orchestrator agent             │
                        │  runs the 5 skills in a fixed order;      │
                        │  live mode vs. dry-run mode               │
                        └───────────────┬──────────────────────────┘
                                        │ invokes
        ┌───────────────┬───────────────┼───────────────┬────────────────┐
        ▼               ▼               ▼               ▼                ▼
  create_cmrs    read_cmrs_daily  update_cmrs_daily  update_assignees  purge_data_logs
        │               │               │               │                │
        │  (SQL fetch)   │  (Jira read)  │ (SQL fetch)   │  (Jira read/   │ (filesystem)
        │                │               │               │   write)       │
        ▼                ▼               ▼               ▼                ▼
   ┌─────────┐      ┌─────────┐     ┌─────────┐     ┌─────────┐      ┌─────────┐
   │ Helper  │      │Atlassian│     │ Helper  │     │Atlassian│      │ Working │
   │ scripts │      │  (MCP)  │     │ scripts │     │  (MCP)  │      │  files  │
   └────┬────┘      └────┬────┘     └────┬────┘     └────┬────┘      └─────────┘
        │                │               │               │
        ▼                ▼               ▼               ▼
  Internal DB view   Jira project    Internal DB view   Jira project

  Cross-cutting governance (Claude Code hooks):
   • PreToolUse  — enforces the mandated Python launcher on shell calls
   • PostToolUse — records an audit line for every Jira (MCP) call
```

### The five skills

| Skill | What it does |
|---|---|
| `create_cmrs` | Creates CMRs for the target week (Sunday → next week, otherwise the current week). De-duplicates per row against Jira before creating anything. |
| `read_cmrs_daily` | Fetches the **previous 2 days'** CMRs from Jira into a working file. The 2-day window catches maintenances that finish the day after they start. |
| `update_cmrs_daily` | Writes actual completion times back to each CMR's *Planned End*; prepends a notice on skipped maintenances. |
| `update_assignees` | Clears the auto-assigned owner on upcoming CMRs. |
| `purge_data_logs` | Removes working files past their retention age; always runs last. |

---

## Running modes
- **DRY-RUN** - Runs in preview mode where no actual changes are made to the tickets. On completion displays what modifications would have happened in live.
- **LIVE-RUN** - Performs all the steps and makes actual changes to the CMRs (create & update).

---

## Running it

**Full pipeline (live):**
```
/run_orchestrator
```

**Preview only — makes no changes** (no files written, no Jira issues created or edited):
```
/run_orchestrator_preview
```

You can also invoke a single skill in plain language, e.g. *"create CMRs for next week"*, *"update CMRs for the last couple of days"*, *"unassign upcoming CMRs"*, or *"purge old working files"*.

### Typical weekly flow
1. `create_cmrs` — file the target week's CMRs.
2. `read_cmrs_daily` → `update_cmrs_daily` — sync actual completion times back to Jira.
3. `update_assignees` — clear backend auto-assignment.
4. `purge_data_logs` — clean up aged files (always last).

---

## Safety & governance

- **Preview before write.** Every skill that changes Jira shows a full preview and asks for confirmation before applying anything.
- **Dry-run mode.** The preview command runs the entire pipeline read-only — nothing is created, edited, or deleted.
- **No duplicates.** `create_cmrs` checks Jira for an existing CMR (by affected systems + planned start) before filing, and surfaces every skip rather than hiding it.
- **Idempotent updates.** Completion times are compared to the minute; an update is staged only when the value actually differs, so re-runs are safe.
- **Ordering guarantee.** Cleanup always runs last, after all Jira work is complete.
- **Governance hooks.** Project conventions (such as the required Python launcher) are enforced automatically, and Jira tool calls are recorded to an audit trail.

---

## Conventions

- **Week:** Monday (start) through Sunday (end).
- **Timezone:** all datetimes are handled in a single fixed business timezone (with daylight-saving awareness).
- **Working files:** never overwritten — a numeric suffix is appended on collision.
- **Naming:** `snake_case` for scripts, functions, skills, and commands.

---

## Requirements (high level)

Running the pipeline requires, on the operator's machine:

- **Claude Code** with this project's plugin/skills installed.
- **Read access to the internal maintenance database** through a SQL Server ODBC driver and an integrated (trusted) connection.
- **Python** available through the mandated launcher, with the database driver package installed.
- **A Jira account** with access to the change-management project, authorized to the Atlassian MCP server.
- **Windows + PowerShell** (the helper scripts and hooks are PowerShell-based).

Exact server, database, project, and field values are kept in the project's internal configuration and reference files.

---

## Further reading

- **[DESIGN.md](DESIGN.md)** — component map, data flow, and the design decisions behind each stage (also infrastructure-clean).
- **`CLAUDE.md`** — operational guidance and the concrete, environment-specific values used by the skills.
