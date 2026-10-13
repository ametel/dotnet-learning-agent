# Demo 1: successful run with dynamic agent selection, approval, and HTML

A real `/prepare-interview` run with live subagents (2026-10-13). Every step passed on its
first attempt, the user approved the validated plan, and the HTML guide was rendered.
The same run is used for [Demo 3](../demo-3-resume-async/README.md): the Claude Code
session was restarted after research and the run was resumed.

Original run ID: `20261013-134101-resume-demo-async-ad8d3d`.

## Input (confirmed by the user)

`confirmed-input.md`: .NET backend, Middle, interview in 10 days, 30 minutes a day for 6 days
(3 hours), only gap **async/await in C#**, hands-on exercises and short interview questions.

## What happened

| # | Step | Owner | Result | Output |
|---|---|---|---|---|
| 1 | requirements | `requirements-formalizer` | passed, attempt 1 | `requirements.md`: 1 mandatory topic, `time_budget_hours: 3.0`, 0 blocking questions |
| 2 | selection | coordinator | recorded | `research-selection.json`: **1 of 3 agents** selected (`dotnet-researcher`); `data-researcher` and `architecture-researcher` not selected, each with a reason |
| 3 | research-dotnet | `dotnet-researcher` | passed, attempt 1 | `research/dotnet.md`: 10 distinct sources, Microsoft Learn MCP |
| 4 | coverage | `quality-validator` | passed, attempt 1 | `validation/coverage.{json,md}`: topic `covered`, 0 blocking, 2 advisory |
| 5 | plan | `study-planner` | passed, attempt 1 | `plan.md` v1: six 30-minute sessions, 3.0 of 3.0 hours |
| 6 | plan-validation | `quality-validator` | passed, attempt 1 | `validation/plan.{json,md}`: 0 blocking, 3 advisory |
| 7 | approval | user | approved | `APPROVE PLAN <run-id> fea645a65820`, captured by the UserPromptSubmit hook and applied by `state.ps1 decide` |
| 8 | render | `scripts/render-guide.ps1` | passed, attempt 1 | `guide.html`, embedding the approved plan hash |

`workflow_status` went `in_progress` → `awaiting_approval` → `approved` → `completed`.

## Files

| File | What it shows |
|---|---|
| `confirmed-input.md`, `requirements.md` | Confirmed input and the formalized requirements (mandatory topics, budget) |
| `research-selection.json` | Dynamic selection, not-selected reasons, and the coverage map |
| `research/dotnet.md` | Grounded research with sources |
| `validation/coverage.*`, `validation/plan.*`, `validation/history/` | Validator reports, archived per attempt |
| `plan.md` | The approved study plan |
| `guide.html` | The rendered guide; open it in a browser |
| `state.snapshot.json` | Sanitized copy of `state.json` (see below) |

## Sanitization

- Artifacts are **byte-identical** to the run, so their SHA-256 matches `artifact_sha256` in
  `state.snapshot.json` (`Get-FileHash plan.md`).
- `state.json` is published as `state.snapshot.json` so the tooling never treats this folder
  as a live run. Subagent IDs are replaced by `<redacted>`, and prompt hashes are removed.
  Paths inside it still name the original run directory.
- **Approval evidence is not published**: `approval/decisions.jsonl` (it holds the session ID
  and the local transcript path) and `approval.json` are left out. The snapshot records that
  an approval was applied; it is not proof that a human approved anything.
- Version snapshots (`versions/`) duplicate the files above and are left out.
