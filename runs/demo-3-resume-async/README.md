# Demo 3: session restart and resume without repeating research

The run of [Demo 1](../demo-1-success-async/README.md) was started in one Claude Code
session, which ended after research had passed. A **new** session continued it with:

```
/prepare-interview resume 20261013-134101-resume-demo-async-ad8d3d
```

## State at the restart

From `../demo-1-success-async/state.snapshot.json`:

| Step | Status before the restart |
|---|---|
| requirements | `passed` (attempt 1, 13:42:05 UTC) |
| research-dotnet | `passed` (attempt 1, 13:44:09 UTC) |
| coverage, plan, plan-validation, approval, render | `pending` |

No step was `running`, so no interrupted attempt had to be recorded.

## What `resume-run.ps1` returned

[`resume-output.json`](resume-output.json) is the exact output of
`scripts/resume-run.ps1 -RunId <run-id>` in the new session:

- `"result": "resumed"`, `"interrupted_recorded": []`,
- `"skipped_steps": ["requirements", "research-dotnet"]`: not run again,
- `"next": { "action": "run-step", "step": "coverage", "attempts_left": 3 }`.

## What happened next

The coordinator continued at the coverage gate (13:46 UTC). Coverage, plan, and plan
validation passed on attempt 1, the user approved, and the guide was rendered. In
`state.snapshot.json`, `research-dotnet` still has a single attempt and a single history
entry, and its `artifact_sha256` is unchanged: **research was not repeated**.

## Not shown here

An interrupted step (one left `running`) is recorded as a failed attempt, counted against
its 3 attempts. That path is covered by `tests/resume.tests.ps1` (fixtures), not by this
run.
