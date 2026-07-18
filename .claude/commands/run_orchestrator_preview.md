---
name: run_orchestrator_preview
description: Runs the CMR orchestrator in dry-run/preview-only mode. Executes all automation steps and shows full previews of what would happen, but does not save any files, does not create any Jira issues, and does not update or unassign any Jira issues. Use this skill whenever the user asks to preview, simulate, dry-run, or test the orchestrator without making real changes.
---

Use the cmr_orchestrator subagent to execute the full CMR automation
workflow. Pass the following signal so the orchestrator activates dry-run mode:

DRY_RUN=true

Report final status when complete.
