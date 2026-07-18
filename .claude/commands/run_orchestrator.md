---
name: run_orchestrator
description: Triggers the CMR orchestrator to run all automation tasks- Create CMRs, Read CMRs & Update CMRS, Unassign newly created CMRs. Also shows full previews of what would happen at each task. Use this skill whenever the user asks to initiate CMR management tasks.
---

Use the cmr_orchestrator subagent to execute the full CMR automation
workflow. Pass the following signal so the orchestrator activates live mode:

DRY_RUN=false

Report final status when complete.