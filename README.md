# dotnet-learning-agent

An educational multi-agent workflow built on [Claude Code](https://claude.com/claude-code)
that creates a **personalized .NET interview preparation guide**.

You start it with the `/prepare-interview` slash command. A coordinator gathers and confirms
your requirements, picks only the research agents your gaps need, runs them in parallel
against Microsoft Learn (MCP) and the web, synthesizes a study plan within your time budget,
validates every intermediate artifact against quality gates, asks for **your** decision,
and renders the approved plan as a self-contained HTML guide.

[CLAUDE.md](CLAUDE.md) is the architectural contract: every rule summarized here is
specified there.

## Contents

- [Architecture](#architecture)
- [Setup (Windows, PowerShell 7, Claude Code)](#setup-windows-powershell-7-claude-code)
- [Usage: start, approve, revise, resume](#usage)
- [Demo runs](#demo-runs)
- [Testing](#testing)
- [Verification with real runs](#verification-with-real-runs)
- [Known limitations](#known-limitations)
- [Layout](#layout)

## Architecture

Hub-and-spoke (CLAUDE.md §2). The coordinator is the main Claude Code session driven by
`/prepare-interview`. Subagents never call each other; they read the inputs the coordinator
names and write only their own artifact. All state lives in files under `runs/<run-id>/`.

```
                        ┌──────────────────────┐
           user ◄──────►│  Coordinator (hub)   │◄──── runs/<run-id>/state.json
                        │  /prepare-interview  │      (scripts/state.ps1 only)
                        └──────────┬───────────┘
              ┌──────────────┬─────┴────────┬───────────────┐
              ▼              ▼              ▼               ▼
        requirements     research       study-planner   quality-validator
        -formalizer     spokes (1–3,                    (coverage + plan)
                        in parallel)
```

| Step | Owner | Artifact | Gate |
|---|---|---|---|
| 1. Requirements | `requirements-formalizer` | `requirements.md` (mandatory topics, budget) | headings, front matter |
| 2. Selection | coordinator | `research-selection.json` | every mandatory topic mapped to exactly one agent |
| 3. Research (parallel) | `dotnet-researcher`, `data-researcher`, `architecture-researcher` | `research/<area>.md` | structure, ≥ 3 sources, Microsoft Learn source |
| 4. Coverage | `quality-validator` | `validation/coverage.json` | schema, every mandatory topic assessed |
| 5. Plan | `study-planner` | `plan.md` | budget, sessions per topic, every URL from research |
| 6. Plan validation | `quality-validator` | `validation/plan.json` | schema, verdict |
| 7. Approval | **you** | `approval.json` (via `state.ps1 decide`) | hook-captured, origin-checked prompt |
| 8. Render | `scripts/render-guide.ps1` | `guide.html` | approval matches the current plan hash |

Key mechanisms:

- **Dynamic selection** (§3): an agent runs only if one of your gaps or requested topics maps
  to it; skipped agents are recorded with a reason.
- **Quality gates and targeted retries** (§6): deterministic checks in `scripts/state.ps1`
  plus the validator's semantic review. A failure re-runs only the owning agent, at most 3
  attempts per artifact; dependent steps are invalidated by input hash (§5.2).
- **Requested revisions** (§6.2): you can ask for changes to a validated plan; only the
  planner and the plan validator run again, and every version is kept in `versions/`.
- **Integrity** (§6.4): a passed artifact edited outside the workflow blocks the run until you
  restore or discard it.
- **Human approval** (§8): your exact `APPROVE`/`REJECT`/`REVISE PLAN` prompt is captured by a
  UserPromptSubmit hook in a hash-chained ledger and checked against the session transcript.
- **Guardrail hooks** (§12): PreToolUse enforces artifact ownership, protected files, and a
  shell allowlist while a run is open; PostToolUse reports integrity violations. Hooks are
  pinned by SHA-256.
- **Resume** (§7): `state.json` is the only memory; a new session continues where the last
  one stopped.
- **Skills** (§13): `artifact-validator` and `html-guide-builder` package the pre-render check
  and the render step.

## Setup (Windows, PowerShell 7, Claude Code)

1. **Install the prerequisites:**
   - [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
     (`winget install Microsoft.PowerShell`). The scripts and hooks run under `pwsh`;
     Windows PowerShell 5.1 is not supported.
   - [Claude Code](https://docs.claude.com/en/docs/claude-code/setup), signed in.
   - Git.
2. **Clone and open the project:**
   ```powershell
   git clone <repository-url> dotnet-learning-agent
   cd dotnet-learning-agent
   claude
   ```
   Trust the folder when Claude Code asks. The project hooks in `.claude/settings.json` then
   run on every prompt and tool call.
3. **Check the hook pins.** The hooks verify the SHA-256 of their own files and of the
   scripts before running. `.gitattributes` checks those files out with LF line endings, so
   the committed pins match. If every tool call is denied with `Hook integrity: ... changed
   since the hooks were pinned`, re-pin and restart Claude Code:
   ```
   ! pwsh -NoProfile -File scripts/pin-hooks.ps1
   ```

### Microsoft Learn MCP server

Research agents use the official [Microsoft Learn MCP Server](https://learn.microsoft.com/api/mcp)
(public, no API key), declared in `.mcp.json`. Project MCP servers need your approval once:

1. Approve `microsoft-learn` when `claude` prompts you, or create
   `.claude/settings.local.json` (git-ignored) with
   `{ "enabledMcpjsonServers": ["microsoft-learn"] }`.
2. Verify:
   ```
   claude mcp get microsoft-learn     # expect: Status: ✔ Connected
   ```
   In a session, `/mcp` lists `microsoft_docs_search`, `microsoft_docs_fetch`, and
   `microsoft_code_sample_search`.

`.claude/settings.json` pre-approves only the Microsoft Learn tools, `WebSearch`, and
`WebFetch` for a few documentation domains, because background research agents cannot
answer permission prompts. Troubleshooting: [CLAUDE.md §9.3](CLAUDE.md).

## Usage

### Start a run

```
/prepare-interview Senior backend .NET developer, interview in 3 weeks, ~5 h/week, weak on async/await internals and EF Core performance
```

The coordinator asks for any missing essentials (role, seniority, timeline, hours, gaps),
shows a summary, and continues only after you confirm it. It then runs the steps above and
reports the agents it selected, each gate's result, and the plan.

### Approve, reject, or revise

When the plan has passed validation, the coordinator shows its version and the first 12
characters of its SHA-256. Submit **one** of these as your whole prompt, typed (or pasted as
a single plain line):

```
APPROVE PLAN <run-id> <hash12>
REJECT PLAN <run-id> <hash12>
REVISE PLAN <run-id> <hash12>: <what to change>
```

- **Approve:** the coordinator runs `state.ps1 decide`, then renders the guide.
- **Reject:** final; the run is closed.
- **Revise:** reopens only the plan. The planner revises it from the validated research using
  your words, and it is validated again; research is not re-run. At most 3 revisions per
  run. You can also start later with `/prepare-interview revise <run-id>`.

Any change to the plan voids an approval; the hash in your command must match the plan you
were shown.

### Resume after a session ends

```
/prepare-interview resume <run-id>
```

`scripts/resume-run.ps1` verifies integrity, records any step left `running` as a failed,
interrupted attempt, and continues at the first unfinished step. Passed steps, including
research, are never repeated.

### View the guide

The guide is `runs/<run-id>/guide.html`: one self-contained page (inline CSS, no scripts, no
external resources). Open it in a browser:

```powershell
Invoke-Item runs\<run-id>\guide.html
```

Do not edit it: its hash is recorded, and a changed guide is an integrity violation.

### Shell commands during a run

While a run is open, the hooks limit Claude's shell to `state.ps1`, the renderer, the resume
script, the test runner, and read-only git. Run anything else yourself with `!`.

## Demo runs

Three sanitized snapshots of real runs with live agents are committed under `runs/demo-*/`.
Each folder has a README with the full step-by-step trace. They are snapshots for reading,
not live runs: `state.json` is published as `state.snapshot.json`, subagent IDs and prompt
hashes are removed, and **no approval evidence** (decision ledger, `approval.json`, session
transcript) is included, so nothing in them proves that a human approved a plan. The
artifacts are byte-identical to the originals, so their SHA-256 matches the snapshot.

| Demo | Input | Shows | Outputs | State transitions |
|---|---|---|---|---|
| [1. Success](runs/demo-1-success-async/README.md) | Middle .NET backend, 10 days, 3 h; gap: async/await in C# | Dynamic selection (1 of 3 agents, reasons for the other 2), all gates passed on attempt 1, user approval, HTML | `requirements.md`, `research-selection.json`, `research/dotnet.md` (10 sources), `validation/*`, `plan.md` (6 × 30 min), `guide.html` | `in_progress` → `awaiting_approval` → `approved` → `completed` |
| [2. Revision](runs/demo-2-revision-efcore/README.md) | Middle+ .NET backend, 7 days, 2.5 h; gap: EF Core performance + 4 requested topics | Requested revision of a validated plan: v1 → v2, `plan-validation` invalidated and re-run, research and coverage untouched; then approval and HTML | `versions/plan-v1.md`, `plan.md` (v2), `revisions/rev-001-request.json`, both plan-validation reports in `validation/history/`, `guide.html` | plan `passed` v1 → revision `rev-001` open → plan `pending` → `passed` v2 → plan-validation `invalidated` → `passed` → revision `completed` → `approved` → `completed` |
| [3. Resume](runs/demo-3-resume-async/README.md) | Demo 1's run, restarted after research | A new session continues with `/prepare-interview resume`; requirements and research are skipped | `resume-output.json` (exact `resume-run.ps1` output); the artifacts are Demo 1's | requirements, research `passed` → session ends → `resumed`, `skipped_steps: [requirements, research-dotnet]` → coverage … render → `completed` |

All other directories under `runs/` are local and git-ignored.

## Testing

`tests/` holds a dependency-free PowerShell 7 suite (no Pester). Each run works in a fresh
temp directory passed to `state.ps1` with `-RunsRoot`; nothing is written to `runs/`.

```
pwsh -NoProfile -File tests/run-tests.ps1                    # everything (≈ 30 min, 5 iterations per concurrency scenario)
pwsh -NoProfile -File tests/run-tests.ps1 -SkipConcurrency   # sequential tests only
pwsh -NoProfile -File tests/run-tests.ps1 -SkipConcurrency -Filter quarantine   # name filter (regex)
pwsh -NoProfile -File tests/run-tests.ps1 -Iterations 25     # heavier concurrency stress
pwsh -NoProfile -File tests/run-tests.ps1 -SensitivityCheck  # prove the tests catch lost updates
pwsh -NoProfile -File tests/run-tests.ps1 -KeepTestRoot      # keep the temp directory
```

The exit code is 0 when every test passes. Agent outputs are fixtures; the suites cover:

| Suite | Tests | Covers |
|---|---|---|
| `state.tests.ps1` | 27 | transitions, 3-attempt limit, malformed artifacts, source rules, selection, stale inputs, `-NoRetry`, isolation of research steps |
| `state.concurrency.tests.ps1` | 8 | parallel `pwsh` processes racing on one run's lock; unlocked readers never see a torn `state.json` |
| `state.synthesis.tests.ps1` | 17 | coverage map, coverage and plan gates, routing of findings to owners, targeted retries, invalidation, retry exhaustion |
| `state.revision.tests.ps1` | 10 | requested revisions, version history, limits, integrity violations with `restore`/`discard` |
| `state.approval.tests.ps1` | 14 | ledger validation, stale/replayed/forged evidence, approve/reject/revise, voiding, `quarantine-ledger` |
| `hooks.tests.ps1` | 16 | the three hooks run as Claude Code runs them: capture, origin check, ownership, protected files, shell policy, integrity reports, pins |
| `render.tests.ps1` | 6 | rendering only with a valid approval, HTML escaping of hostile plan text, guide hash and tamper detection |
| `resume.tests.ps1` | 8 | resume at every stage, interrupted steps as failed attempts, refusal on integrity violations |

Last full run (2026-10-13, Windows 11, PowerShell 7.6, `-Iterations 5`): **106 of 106 passed**
in about 29 minutes. Across 60 concurrent batches every operation overlapped every other one,
and unlocked readers parsed `state.json` 9,598 times with 0 invalid reads. An earlier
`-SensitivityCheck` run showed that a copy of `state.ps1` without the lock produces lost
updates the tests detect, and a mutation check of the approval logic caught all 9 mutants.

## Verification with real runs

All with live subagents and the Microsoft Learn MCP server, on Windows 11 with
PowerShell 7.6 and Claude Code 2.1.296. Only the three demo runs are committed.

- **Parallel research (2026-10-12):** three research agents launched in one message; their
  transcripts started within 30 ms of each other and overlapped for about 85 seconds. 27
  `microsoft_docs_search` calls and 1 `microsoft_docs_fetch`, no tool errors; 6 cited
  Microsoft Learn URLs spot-checked, all supported their claims.
- **Full synthesis path (2026-10-12):** requirements → research → coverage → plan → plan
  validation, every gate passed on attempt 1 (15.0 of 15 hours planned).
- **Revision (2026-10-12):** [Demo 2](runs/demo-2-revision-efcore/README.md).
- **Hooks (2026-10-13):** headless `claude -p` sessions in an isolated scratch copy: decision
  capture and transcript origin check, notifications never recorded, bypass attempts
  (direct writes to approval files, `plan.md`, `guide.html`, shell redirects, nested
  sessions) denied, ownership by `agent_type`, PostToolUse integrity reports, and pin
  mismatches failing closed.
- **Interactive approval and rendering (2026-10-13):** Demo 2. The first approval was
  refused because interactive prompts carry `origin.kind: human`; the origin check was fixed
  and the second approval applied. The first guide lost numbered list items; the renderer was
  fixed with a regression test and the guide was discarded through the integrity resolution
  and rendered again, without a new plan version or approval.
- **Resume (2026-10-13):** [Demo 3](runs/demo-3-resume-async/README.md), then
  [Demo 1](runs/demo-1-success-async/README.md) to completion.

## Known limitations

- **Hooks are guardrails, not an OS security boundary** (CLAUDE.md §12.5). They see only
  Claude Code's own prompts and tool calls. `!` commands, other terminals and editors, and
  sessions started without the project hooks can write any file you can, including the
  decision ledger and the session transcript.
- **The origin check is not proof of identity.** `decide` checks that Claude Code recorded
  your prompt as typed input with the same text. It does not prove who typed it or
  distinguish pasted text. Prompts that Claude Code wraps in markup (some pastes) are never
  captured; type the command or paste it as one plain line.
- **Paths exercised only with fixtures:** gate-failure retries and routing, a failed or
  retried revision, integrity resolution with `restore`, ledger quarantine, rejection, and
  resume of an interrupted (`running`) step. None of the real runs hit them.
- **Runs created before Phase 3B cannot be approved.** Their plan has no version number; the
  approval hook would record `plan_version: 0`, which the ledger rejects as malformed, and the
  run then needs `quarantine-ledger`. Do not submit a decision for such a run.
- **Semantic checks depend on the validator.** Depth of coverage, conflicts, unsupported
  claims, and personalization come from `quality-validator`, a model; the scripts check only
  that its report is well-formed and self-consistent. It checks at most 5 Microsoft Learn
  pages per report.
- **Coverage is enforced for mandatory topics only** (your stated gaps and requested topics).
  Optional topics produce advisory findings only.
- **Only the plan can be revised**, one revision at a time, after plan validation passed.
  Changes to confirmed requirements or anything needing new research are not possible;
  re-running requirements is not supported. A revision that runs out of attempts fails the
  run; earlier versions stay in `versions/`, but there is no rollback command.
- **Research is not invalidated automatically:** a changed `requirements.md` or
  `confirmed-input.md` blocks research instead.
- **Integrity covers each step's main artifact.** Validator summaries, `confirmed-input.md`,
  and `research-selection.json` are not hash-checked.
- **Resume costs an interrupted attempt.** Work done before the session ended is not reused.
  A guide written by an interrupted render must be moved aside before resuming.
- **The guide renders the planner's Markdown subset** (headings, tables, lists, code, bold,
  links); anything else appears as escaped text. One HTML guide per approval; no PDF.
- **The plan gate parses only the planner's format.** A differently formatted plan fails the
  gate and is retried.
- **Strict shell mode** applies while any run is open (not completed, rejected, or failed,
  and updated within 24 hours). An abandoned run stops restricting the shell after 24 hours.
- **Editing a hook or a pinned script blocks the session's tools** until you re-pin and
  restart Claude Code (fail-closed by design).
- **State locking is tested on Windows (NTFS) only.** On Linux and macOS, .NET's emulation of
  `FileShare.None` has a known race the tests do not cover.

## Layout

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Architectural contract and rules |
| `.claude/agents/` | Subagents: requirements, 3 research, validator, planner |
| `.claude/commands/` | `/prepare-interview` (start, `resume`, `revise`) |
| `.claude/skills/` | `artifact-validator`, `html-guide-builder` |
| `.claude/hooks/` | UserPromptSubmit, PreToolUse, PostToolUse, shared code, approval policy |
| `.claude/settings.json` | Permissions and pinned hook launchers |
| `.mcp.json` | Microsoft Learn MCP server |
| `scripts/` | `state.ps1` (state machine and gates), `render-guide.ps1`, `resume-run.ps1`, `pin-hooks.ps1` |
| `tests/` | Test suite (`run-tests.ps1`) |
| `runs/demo-*/` | Committed demo snapshots; every other run is git-ignored |
| `artifacts/`, `templates/` | Reserved (empty) |
