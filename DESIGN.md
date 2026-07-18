This document describes the components, data flow, and design 
decisions behind the SQL Maintenance CMR Manager. It is written 
for engineers evaluating, extending, or adapting the system. 
Concrete environment values (servers, databases, field IDs) 
live in `CLAUDE.md` and are not referenced here.

# Architecture — SQL Maintenance CMR Manager

This document explains **what the system is built from** and **why it is built that way**. The components are described by role, not by server/database/endpoint names. Concrete values live in `CLAUDE.md`.

---

## 1. Design philosophy

The system exists to keep Jira change tickets (CMRs) truthful for **fully automated** maintenances that no human files or owns. That goal shaped three foundational choices:

- **Claude Code–native, no server.** Rather than a standalone service with its own deployment, scheduler, and credentials store, the whole pipeline is expressed as an **orchestrator agent + skills + MCP tool calls**. The operator's existing Claude Code environment provides identity, connectivity, and scheduling. There is nothing to host, patch, or monitor separately.
- **Decomposed into single-purpose skills.** Each stage of the lifecycle is an independent, self-contained skill with its own instructions, working directory, and preview. This makes each stage runnable in isolation, testable on its own, and safe to reorder or re-run.
- **Safe-by-default.** Because the pipeline writes to a system of record (Jira) that a change-management audience reads, every write is previewed, a full dry-run mode exists, duplicates are prevented, and updates are idempotent.

---

## 2. Component map

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

**Two external systems:**
- **Internal database** — the source of truth for *what maintenances are scheduled* and *when they actually finished*. Reached read-only through small Python helper scripts.
- **Jira** — the system of record for change tickets. Reached through the **Atlassian MCP** server for both reads (JQL) and writes (create/edit).

Everything else (the agent, skills, scripts, hooks, working files) is local to the project.

---

## 3. Data flow

```
 SCHEDULE (future)                          COMPLETION (past)
 ─────────────────                          ──────────────────
 Internal DB view                           Internal DB view
       │ fetch week                                │ fetch last 2 days
       ▼                                           ▼
   create_cmrs                                update_cmrs_daily ◄── working file
       │ dedupe vs Jira                            │ match by affected systems   (from read_cmrs_daily)
       ▼                                           ▼
   Jira: create CMRs                          Jira: set actual Planned End
                                                   (+ skip notice if skipped)

                    read_cmrs_daily:  Jira ──► working file  (feeds update_cmrs_daily)
                    update_assignees: Jira ──► clear auto-assigned owner
                    purge_data_logs:  working files ──► delete when past retention
```

The pipeline runs **forward through the lifecycle**: a maintenance is *scheduled* → CMR created → maintenance *runs* → actual end time written back → ticket left unassigned → old artifacts cleaned up.

---

## 4. The pipeline stages and why each exists

### `create_cmrs` — file the week's tickets
Reads the target Monday–Sunday week from the database and files one CMR per maintenance.
**Why the design is what it is:**
- **Target-week rule** (Sunday → next week, otherwise current week) matches how the team plans: on the changeover day you look ahead, mid-week you're working the live week.
- **Two-layer duplicate prevention** — a local file guard *and* a per-row check against Jira (by *affected systems + planned start*). The Jira check is authoritative because the local file can be missing or stale; the pair makes running the skill twice harmless.
- **Skips are never silent** — anything already present is listed in the preview, so a human can see nothing real was dropped.

### `read_cmrs_daily` — snapshot recent tickets
Pulls the just-filed CMRs from Jira into a working file that `update_cmrs_daily` consumes.
**Why a 2-day window (not just "yesterday"):** a maintenance can start late one day and finish early the next. If the pipeline only ever looked at a single prior day, such a maintenance would be read before it finished and then never revisited. A rolling 2-day window guarantees it is seen again after completion.

### `update_cmrs_daily` — write back reality
Fetches actual completion times and updates each CMR's *Planned End*.
**Why the design is what it is:**
- **Match by affected systems**, not by ticket summary — summaries drift between systems, the affected-systems key is stable.
- **Minute-precision, change-only updates** — completion times are compared to the minute; an edit is made only when the value truly differs. This makes the wider 2-day window safe to re-run: already-correct tickets are left untouched.
- **Skip handling** — a maintenance recorded as skipped gets an explicit notice prepended to its description, so the ticket reflects that it didn't actually run.

### `update_assignees` — keep automated changes ownerless
Clears the owner Jira's backend auto-assigns to newly created tickets.
**Why it exists and why it runs late:** these maintenances are automated and have no human owner yet, so an auto-assigned owner is misleading. The backend assigns asynchronously, so this step runs **after** the create/read/update steps — the time gap lets the assignment settle before it's cleared. It is idempotent (only touches tickets that currently have an owner).

### `purge_data_logs` — housekeeping
Removes working files once they age out, and trims very old entries from the audit trail.
**Why it runs last:** cleanup must never race a Jira operation. Making it strictly the final step removes any chance of deleting a file another step still needs.

---

## 5. Cross-cutting concerns and why

| Concern | Mechanism | Why | Result |
|---|---|---|---|
| **Accidental writes during a "preview"** | A dry-run mode threaded through the orchestrator; every write skill checks it and stops at the preview. | The worst failure mode — real Jira writes during a simulation — becomes structurally impossible. | Zero unintended Jira writes in production runs. |
| **Human oversight** | Each write skill previews changes and confirms via an in-workflow question. | CMRs are audience-visible; a person signs off before the system of record changes. | Every Jira change is human-approved before it is applied. |
| **Tooling drift** | A hook rejects the wrong Python launcher on every shell call. | Guarantees the environment stays consistent regardless of who runs it, without relying on people remembering a convention. | Consistent execution environment enforced automatically across all operators. |
| **Auditability** | A hook records every Jira tool call to an append-only trail. | Provides an independent record of what the automation did against Jira. | Full audit trail of every create, update, and read against Jira. |
| **Correctness of dates** | Dates are computed via the shell rather than by hand; a single fixed business timezone is used throughout. | Removes off-by-one and DST mistakes at week/day boundaries. | No date-boundary errors across timezone transitions or week rollovers. |

---

## 6. Working artifacts

Each skill keeps its outputs in its own working directory:

- **Data files** — snapshots of fetched tickets, staged updates, and an unassignment audit. Used to pass state between stages and for troubleshooting.
- **Logs** — per-run execution records.
- **Retention** — both are pruned by `purge_data_logs` once past their age threshold; the audit trail file is kept but its oldest entries are trimmed.

Files are never overwritten — a numeric suffix is appended on name collision, so history is preserved within the retention window.

---

## 7. Why this shape holds up

- **Idempotent + duplicate-safe** → the pipeline can run on any schedule, be re-run after a failure, or be triggered manually, without corrupting the ticket set.
- **Stage isolation** → a failure in one stage (e.g. the database being temporarily unreadable) doesn't block the others; the failed stage simply recovers on the next run because of the rolling window.
- **No bespoke server** → nothing extra to deploy, secure, or keep alive; the automation lives where the operator already works and inherits that environment's identity and access.

---

## 8. Extending or changing it

- **New pipeline stage** → add a new skill folder and register it in the orchestrator's ordered list.
- **Different cadence / windows** → the target-week rule and the read/update look-back window are the two knobs that define timing behavior.
- **Environment changes** (server, database view, Jira project, field IDs) → confined to the helper scripts, `CLAUDE.md`, and `referenceObjects/`; the skill and agent logic is environment-agnostic.
