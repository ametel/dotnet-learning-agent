# dotnet-learning-agent

An educational multi-agent workflow built on [Claude Code](https://claude.com/claude-code)
that creates a **personalized .NET interview preparation guide**.

The planned entry point is a `/prepare-interview` slash command. A coordinator agent gathers
your requirements, then dynamically selects specialized subagents to research the relevant
.NET topics with external tools. It assembles a personalized learning plan, validates every
intermediate artifact, asks for your approval, and renders the final guide as HTML.

## Status

🚧 **Implementation in progress (Phase 3A).** `/prepare-interview` runs these steps, then
stops:

1. It gathers and confirms your requirements. The `requirements-formalizer` writes
   `requirements.md`, including your **mandatory topics** (your stated gaps and requested
   topics) and your **time budget**.
2. It selects only the relevant research agents (`dotnet-researcher`, `data-researcher`,
   `architecture-researcher`) and maps every mandatory topic to one of them.
3. It launches the research agents in parallel.
4. The `quality-validator` runs the **global coverage gate**: do the research artifacts
   together cover every mandatory topic?
5. The `study-planner` synthesizes `plan.md` within your budget, citing only sources found
   in the research.
6. The validator runs the **plan quality gate**.

A failed gate re-runs only the agent that owns the problem (at most 3 attempts per
artifact), and dependent steps are invalidated and regenerated. Human approval and HTML
generation are not implemented yet.

**Gate-failure retries vs. requested revisions.**
- **A retry** is automatic. It happens when a gate fails or a validator finds a
  **blocking** problem, and it counts against the owner's 3 attempts.
- **A revision** is a deliberate change to an artifact that already **passed**. It covers
  acting on an advisory finding, or the user's "request changes" at approval. Revisions
  will be tracked separately from the retry budget. They are **not implemented yet**, so a
  passed artifact is final for its run (CLAUDE.md §6.2).

### Verified end-to-end run of Phase 3A (2026-10-12)

One real `/prepare-interview` run with live agents went from requirements through plan
validation. The run data stays local (`runs/` is git-ignored), so it is not committed.

- **Requirements:** passed on attempt 1. There were 4 mandatory topics, a 15-hour budget
  derived from the user's own numbers, 0 blocking questions, and 12 non-blocking ones.
- **Research:** all three agents ran in parallel and passed on attempt 1, with 20, 14, and
  16 distinct sources. The coordinator spot-checked 6 cited URLs (2 per artifact), and all
  6 supported their claims.
- **Coverage gate:** `pass` on attempt 1. All 4 mandatory topics were `covered`, with 0
  blocking and 5 advisory findings.
- **Plan:** passed the deterministic gate on attempt 1. It schedules 15 sessions of 60
  minutes (15.0 of 15 hours), with theory, practice, and interview sessions for every
  mandatory topic, plus revision and a mock interview. Every URL comes from research.
- **Plan validation:** `pass` on attempt 1, with 0 blocking and 4 advisory findings. The
  run ended `paused`, with `next_step: approval (not implemented yet)`. Both validator
  reports are archived in `validation/history/`.
- **Not exercised by this run:** no gate failed, so targeted retries, routing, and
  invalidation were tested by the fixture suite only.

A review of the advisory findings confirmed one real traceability error. The plan cited
two queue pages for "avoid synchronous HTTP chains between services". Neither page
supports that claim, but research cites a page that does. The plan also gave two
~60-minute exercises 50-minute slots. Neither problem was blocking under the severity
policy. Both could not be fixed in this run, because a passed plan cannot be reopened
(see below).

### Verified end-to-end run of the research phase (2026-10-12, Phase 2B)

One real `/prepare-interview` run exercised the whole Phase 2B path, up to and including
research. The run data stays
local (`runs/` is git-ignored), so it is not committed.

- **Requirements:** `requirements-formalizer` passed the gate on attempt 1 with 0 blocking
  questions.
- **Selection:** all three research agents were selected, each topic was mapped to exactly
  one agent, and `state.ps1 select` accepted the selection.
- **Parallel execution:** the coordinator issued the three `Agent` calls in a single
  assistant message. The subagent transcripts started within 30 ms of each other and
  overlapped for about 85 seconds. Each one finished in about 1.5 minutes.
- **Microsoft Learn MCP:** every research agent made successful MCP calls. In total there
  were 27 `microsoft_docs_search` calls and 1 `microsoft_docs_fetch` call, with no tool
  errors. Agents used `WebSearch`/`WebFetch` only for non-Microsoft sources.
- **Gates:** all three research steps `passed` on attempt 1, with 15–20 distinct sources
  each. `state.json` recorded each step's status, attempts, input hashes, artifact hash,
  and agent ID, and the run ended with `workflow_status: paused`. The coordinator
  spot-checked 6 cited Microsoft Learn URLs (2 per artifact) with `microsoft_docs_fetch`,
  and all 6 supported the claims.

### Known limitations

- **Only one real Phase 3A run, with no gate failures.** Retries, routing, and
  invalidation have been tested with fixtures only.
- **Passed plans cannot be reopened.** A plan that passed its gates cannot be sent back to
  `study-planner`, either to fix advisory findings or because the user asked for changes.
- **Advisory findings are recorded but not routed.** Only blocking findings trigger a
  retry. Advisory findings stay in `validation/*.json` and are reported to the user.
- **Manual edits to a passed artifact are only partly detected.** Editing `plan.md` by hand
  invalidates plan validation, but the `plan` step itself stays `passed` with an outdated
  hash. The same gap applies to every passed artifact (CLAUDE.md §6.3).
- **URLs containing an apostrophe are truncated.** `Get-Urls` in `state.ps1` stops at `'`.
  Traceability still matches, because research and plan are parsed the same way, but source
  counts and reported URLs can be wrong.
- **Semantic checks depend on the validator.** Depth of coverage, conflicts, unsupported
  claims, personalization, and session lengths come from `quality-validator`, a model. The
  script checks only that its report is well-formed and self-consistent. A validator that
  wrongly passes something is not caught. It may verify at most 5 Microsoft Learn pages per
  report and no other domains.
- **Coverage depends on the mandatory-topic list.** The global gate checks only
  `mandatory_topics`. A gap the formalizer leaves out of that list (the coordinator is told
  to check) is not enforced. Optional topics only produce advisory findings, so in the
  verified run, EF Core optimistic concurrency would be advisory unless the user named it.
- **Limited invalidation.** Downstream steps (coverage, plan, plan validation) are
  invalidated automatically. Research steps are not: a changed `requirements.md` or
  `confirmed-input.md` blocks research instead, and re-running requirements is not
  supported. Resume is not implemented (CLAUDE.md §7).
- **No approval or HTML yet.** The run stops after plan validation.
- **The plan gate parses only its own format.** It reads the schedule table, front matter,
  and URLs in the exact format the `study-planner` prompt defines. A differently formatted
  but valid plan fails the gate and is retried.
- No hooks enforce artifact ownership or the approval-before-HTML rule. The coordinator
  prompt and the agents' instructions are the only enforcement.
- State locking is tested only on Windows (NTFS). On Linux and macOS, .NET emulates
  `FileShare.None` with advisory locks, and `DeleteOnClose` unlinks the lock file. That
  combination has a known race that the tests do not cover.
- Only `state.ps1` operations take the lock. Readers outside it (`state.ps1 show`, the
  `Read` tool) never see a torn file, because writes are atomic renames. However, they can
  read a version that is one update old.

## Testing

`tests/` holds a dependency-free PowerShell 7 test suite for `scripts/state.ps1`. It does
not need Pester. The installed Pester 3.4 is the Windows PowerShell inbox version and is
not used.

```
pwsh -NoProfile -File tests/run-tests.ps1                    # all tests (5 iterations per concurrency scenario)
pwsh -NoProfile -File tests/run-tests.ps1 -SkipConcurrency   # sequential and Phase 3A tests only (~5 min)
pwsh -NoProfile -File tests/run-tests.ps1 -Iterations 25     # heavier concurrency stress
pwsh -NoProfile -File tests/run-tests.ps1 -SensitivityCheck  # also prove the tests catch lost updates
pwsh -NoProfile -File tests/run-tests.ps1 -KeepTestRoot      # keep the temp directory for inspection
```

The exit code is 0 when every test passes. Every run works in a fresh directory under the
system temp folder, passed to `state.ps1` with `-RunsRoot`, and deletes it at the end.
Nothing is written to `runs/`.

- **Phase 3A tests (17, `tests/state.synthesis.tests.ps1`):** agent outputs are fixtures.
  These cover:
  - the mandatory-topic and time-budget front matter,
  - the selection coverage map, including stopping on an unmapped mandatory topic,
  - the full path through coverage, plan, and plan validation,
  - an absent optional topic (advisory only; a blocking optional finding is rejected),
  - a missing mandatory topic, which reopens only the owning research agent,
  - targeted research retry with a fresh coverage budget,
  - a coordinator-owned finding (non-retryable),
  - malformed validator reports (only the validator is retried),
  - plan gate failures: over budget, budget mismatch, untraceable URL, missing topic,
    planned-hours mismatch, wrong `research_inputs`, missing interview session,
  - an unspecified budget,
  - plan validation blaming the planner, and blaming research (whole-chain invalidation),
  - downstream invalidation after edits, and stale attempts,
  - retry exhaustion for research, the plan, and the validator.
- **Sequential state tests (27):** these cover:
  - state transitions and the 3-attempt retry limit,
  - malformed requirements and research artifacts,
  - source rules (at least 3 distinct URLs, counted only under `## Sources`, plus a
    Microsoft Learn URL for `dotnet` and `data`),
  - selection validation,
  - stale-input detection,
  - `-NoRetry`,
  - isolation of a failing research step from the others,
  - lock release when `state.ps1` runs inside the caller's process.
- **Concurrency tests (8):** each operation runs in its own `pwsh` process. The processes
  wait on a shared "go" file, so they start within milliseconds of each other. The
  scenarios are:
  - 8 processes racing to start the same step,
  - a 12-process storm across 3 steps,
  - concurrent start/complete of all research steps,
  - mixed pass, fail and no-retry outcomes,
  - 3 rounds of concurrent start/fail that must account for every attempt,
  - writers running while 2 processes read `state.json` without the lock,
  - waiting for a held lock,
  - lock timeout, and recovery after the lock holder is killed.

  After every operation the tests check that `state.json` parses. After every batch they
  check that no `state.lock` or temp file is left behind.

Last full run (2026-10-12, Phase 3A, Windows 11, PowerShell 7.6, `-Iterations 5`):

- **52 of 52 tests passed** in about 7.6 minutes.
- **Overlap:** there were 60 concurrent batches. In all 60, every operation overlapped
  every other one, and start times were spread by 1 ms on average (13 ms at most).
- **Readers:** unlocked readers parsed `state.json` 7,262 times and saw 0 invalid reads.

The concurrency tests exercise the research steps. The Phase 3A steps run one at a time by
design, so they are tested sequentially.

Phase 2C stress run (`-Iterations 10 -SensitivityCheck`), before Phase 3A:

- **35 of 35 tests passed** in about 6.5 minutes.
- **Overlap:** there were 120 concurrent batches. In all 120, every operation overlapped
  every other one, and start times were spread by 1 ms on average (26 ms at most).
- **Readers:** the unlocked readers parsed `state.json` 14,413 times and saw 0 invalid
  reads.
- **Sensitivity check:** a copy of `state.ps1` with the lock disabled produced 30
  invariant violations in 10 storm rounds. That shows the concurrency tests detect lost
  updates.

Requires [Claude Code](https://claude.com/claude-code) and PowerShell 7+ (`pwsh`) for the
state helper `scripts/state.ps1`.

## Setup: Microsoft Learn MCP server

Research agents use the official [Microsoft Learn MCP Server](https://learn.microsoft.com/api/mcp)
(no API key needed), configured in `.mcp.json`. Project MCP servers need your approval once:

1. Run `claude` in the repo root and approve `microsoft-learn` when prompted. Alternatively,
   create `.claude/settings.local.json` (git-ignored) with
   `{ "enabledMcpjsonServers": ["microsoft-learn"] }`.
2. Verify the connection:
   ```
   claude mcp get microsoft-learn     # expect: Status: ✔ Connected
   ```
   In a session, `/mcp` lists its tools: `microsoft_docs_search`, `microsoft_docs_fetch`,
   and `microsoft_code_sample_search`.

`.claude/settings.json` pre-approves only the Microsoft Learn MCP tools, `WebSearch`, and
`WebFetch` for a few domains. Background research agents can't fetch pages from any other
site; they note this in their output instead. See [CLAUDE.md §9](CLAUDE.md) for details and
troubleshooting.

```
/prepare-interview Senior backend .NET developer, interview in 3 weeks, ~8 h/week, weak on concurrency and EF Core performance
```

See [CLAUDE.md](CLAUDE.md) for the architecture and design rules.

## Layout

| Path               | Purpose                                     |
|--------------------|---------------------------------------------|
| `.claude/agents/`  | Subagent definitions (requirements, 3 research, validator, planner) |
| `.claude/commands/`| `/prepare-interview` command (Phase 3A scope) |
| `.claude/skills/`  | Reusable skills (planned)                   |
| `.claude/hooks/`   | Guardrail hooks (planned)                   |
| `scripts/`         | Deterministic helpers (`state.ps1`)          |
| `tests/`           | Test suite for `state.ps1` (`run-tests.ps1`) |
| `artifacts/`       | Shared reference material (planned)         |
| `runs/`            | Per-run state and outputs; `runs/demo-*/` is committed |
| `templates/`       | Final HTML templates (planned)              |
