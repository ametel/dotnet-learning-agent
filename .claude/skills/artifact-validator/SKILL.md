---
name: artifact-validator
description: Check that a dotnet-learning-agent run's artifacts (requirements, research, coverage and plan reports, plan, approval, guide) have the required structure and content and are intact, using the project's existing deterministic checks. Use before relying on an artifact, before rendering, or when asked whether a run is valid. Read-only; never fixes or edits artifacts.
allowed-tools: Read, Grep, Glob, Bash(pwsh -NoProfile -File scripts/state.ps1:*)
---

# Artifact validator

Checks a run's artifacts against the rules the workflow already enforces (CLAUDE.md §5, §6,
§8, §9). The deterministic rules live in `scripts/state.ps1`; this skill tells you which
check to run and how to read the result. It never re-implements a gate and never edits
anything: a problem goes back to the artifact's owner through the workflow (a gate retry, a
user-requested revision, or `resolve` for an integrity violation).

## 1. Integrity and approval status (always first)

```
pwsh -NoProfile -File scripts/state.ps1 ledger-status -RunId <run-id>
```

Read-only, no lock. It recomputes every passed artifact's SHA-256 from disk. Report:

- `blockers` that start with `integrity violation:` (a passed artifact, `approval.json`, a
  consumed ledger entry, or an unauthorized `guide.html` changed), and the other blockers;
- `approval_status`, `plan_version`, `plan_sha256` versus `accepted_plan_sha256` (they must
  be equal);
- `ledger_valid` and `ledger_problems`; `quarantine_in_progress`.

To **record** a violation and block the run, use `state.ps1 verify -RunId <run-id>`. It
writes `state.json`, so run it only when you found a violation or were asked to.

## 2. Structure and content, per artifact

Read `runs/<run-id>/state.json` (`steps.<step>.status`, `history`, `artifact_sha256`) and the
artifact. A step that `passed` already met its gate when it passed; integrity (§1) shows
whether it is still the accepted content. For an artifact that has not passed, check it
against the gate rules below and report each problem with the rule it breaks. Do not run
`state.ps1 complete` to validate: it records a gate result and is only for a running step.

| Artifact | Gate rules (`state.ps1`) |
|---|---|
| `requirements.md` | Headings: `# Interview Preparation Requirements`, `## Summary`, `## Target Role and Seniority`, `## Topics`, `## Knowledge Gaps`, `## Time Availability`, `## Learning Preferences`, `## Constraints`, `## Acceptance Criteria`, `## Open Questions and Assumptions`. Front matter `blocking_open_questions` (integer), `mandatory_topics` (the user's stated gaps and requested topics, verbatim), `time_budget_hours` (a number only when the user's numbers determine it, else `unspecified`). |
| `research/<area>.md` | `generated_by` = the area's agent. Headings `## Scope`, `## Findings` (one `### <assigned topic>` per topic), `## Interview Questions`, `## Hands-on Exercises`, `## Sources`, `## Gaps and Limitations`. At least 3 distinct URLs under `## Sources`; a `learn.microsoft.com` URL for `dotnet` and `data`. |
| `validation/{coverage,plan}.json` | `report`, `run_id`, `generated_by: quality-validator`, `verdict` (`pass`/`fail`); `mandatory_topics[]` (`topic`, `status` covered/partial/missing; each mandatory topic exactly once); `findings[]` (`severity`, `category`, `owner`, `topic`, `message`, `fix`); a topic that is not covered has a blocking finding; an `optional_topic` finding is never blocking; the verdict matches the blocking findings; the `.md` summary exists. |
| `plan.md` | Front matter `budget_hours`, `planned_hours`, `research_inputs`. Headings `## Summary`, `## Assumptions`, `## Time Budget`, `## Schedule`, `## Topic Plans`, `## Revision and Mock Interviews`, `## Sources`. One `### <mandatory topic>` with a source per topic; theory, practice, and interview sessions per mandatory topic plus a revision session; schedule minutes total ≤ `budget_hours` and equal `planned_hours`; **every URL appears in a research artifact**. |
| `approval.json` | Written only by `state.ps1 decide`; never evidence. Valid only if `steps.approval.status` is `approved` and its `plan_sha256` equals the current plan hash (§1). |
| `approval/decisions.jsonl` | Written only by the UserPromptSubmit hook. `ledger_valid` (§1) covers its structure and chain. |
| `guide.html` | Written only by `scripts/render-guide.ps1`. Valid only if `steps.render.status` is `passed`, its hash is unchanged (§1), and `<meta name="plan-sha256">` equals the approved plan hash. |

## 3. Report

List, per artifact: OK, or each problem with the rule and the owner (`steps.<step>.agent`).
Say which problems block the next step. Never edit an artifact, `state.json`, or anything
under `approval/`; never start, complete, or fail a step from this skill.
