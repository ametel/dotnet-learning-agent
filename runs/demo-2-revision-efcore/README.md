# Demo 2: plan revision with preserved history and targeted revalidation

A real `/prepare-interview` run with live subagents (2026-10-12/13). The validated plan was
revised at the user's request from version 1 to version 2. Only the planner and the plan
validator ran again; research and coverage were not touched. The revised plan was then
approved and rendered.

Original run ID: `20261012-193618-middle-backend-efcore-06d058`.

## Input (confirmed by the user)

`confirmed-input.md`: .NET backend, Middle+, interview in 7 days, 30 minutes a day for 5 days
(2.5 hours), gap **EF Core performance**, requested topics query optimization, AsNoTracking,
N+1 queries, indexing.

## What happened

| Time (UTC) | Step | Result |
|---|---|---|
| 10-12 19:37 | requirements | passed, attempt 1: 5 mandatory topics, `time_budget_hours: 2.5` |
| 10-12 19:37 | selection | **1 of 3 agents**: `data-researcher` (all 5 topics); the other two not selected, with reasons |
| 10-12 19:39 | research-data | passed, attempt 1, 22 distinct sources |
| 10-12 19:41 | coverage | passed, attempt 1, 5/5 topics `covered`, 2 advisory |
| 10-12 19:43 | plan **v1** | passed, attempt 1 → `versions/plan-v1.md` |
| 10-12 19:44 | plan-validation v1 | passed, attempt 1, 4 advisory findings (P1–P4) |
| 10-12 19:47 | **revision `rev-001` opened** | the user picked P1–P4 and added constraints (`revisions/rev-001-request.json`). `plan` reopened with a fresh budget; `plan-validation` **invalidated** (`"input step 'plan' is pending"`). Research and coverage stayed `passed` |
| 10-12 19:50 | plan **v2** | passed, attempt 1 of the new version → `versions/plan-v2.md` |
| 10-12 19:51 | plan-validation v2 | passed, attempt 1, 3 advisory. `rev-001` → `completed`, `result_version: 2` |
| 10-13 10:56 | approval `dec-001` | **refused**: the origin check did not yet accept interactive prompts (`origin.kind: human`). Consumed, never applied |
| 10-13 11:03 | approval `dec-002` | applied after the fix: plan v2 approved |
| 10-13 12:20 | render v1 | passed, but the guide lost numbered list items (renderer defect) |
| 10-13 12:29 | integrity `discard` of render v1; render **v2** | the defect was fixed with a regression test, and the guide was rendered again from the **same** approval and plan |

The revision predates the REVISE PLAN hook (Phase 4B); it was opened with
`state.ps1 revise`, with an explicit user confirmation. Today the same request is a
`REVISE PLAN <run-id> <hash12>: <changes>` prompt.

## What to look at

- `versions/plan-v1.md` vs `plan.md` (= `versions/plan-v2.md`): what changed.
- `revisions/rev-001-request.json`: the user's request.
- `validation/history/`: the coverage report and **both** plan-validation reports
  (19:44 for v1, 19:51 for v2), kept for traceability.
- `state.snapshot.json`: `steps.plan.history` and `accepted_versions` (v1 and v2, tagged
  `rev-001`), `steps.plan-validation.history` (the `invalidated` entry),
  `revisions[0]` (base version, base hash, result version), and the unchanged
  `research-data` and `coverage` steps (one attempt each).
- `guide.html`: the rendered guide for plan v2.

## Sanitization

Same rules as [Demo 1](../demo-1-success-async/README.md#sanitization): artifacts are
byte-identical, `state.json` is published as `state.snapshot.json` with subagent IDs and
prompt hashes removed, and no approval evidence (`approval/decisions.jsonl`,
`approval.json`) is published. The defective first guide and the duplicate version
snapshots are left out.
