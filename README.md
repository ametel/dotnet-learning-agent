# dotnet-learning-agent

An educational multi-agent workflow built on [Claude Code](https://claude.com/claude-code)
that creates a **personalized .NET interview preparation guide**.

The planned entry point is a `/prepare-interview` slash command. A coordinator agent gathers
your requirements, then dynamically selects specialized subagents to research the relevant
.NET topics with external tools. It assembles a personalized learning plan, validates every
intermediate artifact, asks for your approval, and renders the final guide as HTML.

## Status

🚧 **Implementation in progress (Phase 5).** `/prepare-interview` runs these steps:

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

7. It asks for **your decision** on the validated plan (CLAUDE.md §8).
8. After your approval, it renders the **HTML study guide** `runs/<run-id>/guide.html`
   (CLAUDE.md §8.3), using the `artifact-validator` and `html-guide-builder` Skills.

**The guide (Phase 5).** `scripts/render-guide.ps1` turns the approved `plan.md` into one
self-contained HTML page: the schedule, every topic's theory, exercises, and interview
questions, revision and mock interviews, and the sources, with section navigation and a
light/dark stylesheet. It has no scripts and loads nothing external, and every piece of plan
text is HTML-escaped. It runs only through `state.ps1`'s render step: rendering is refused
unless you approved exactly the current plan (its SHA-256), the guide embeds that hash, and
its own hash is recorded so later tampering is detected. Changing the plan voids the approval
and the guide.

A failed gate re-runs only the agent that owns the problem (at most 3 attempts per
artifact), and dependent steps are invalidated and regenerated.

**Your decision (Phase 4B, CLAUDE.md §8 and §12).** The coordinator shows the plan version
and the first 12 characters of its SHA-256. You answer with one of these as your whole
prompt:

```
APPROVE PLAN <run-id> <hash12>
REJECT PLAN <run-id> <hash12>
REVISE PLAN <run-id> <hash12>: <what to change>
```

A UserPromptSubmit hook records exactly that prompt as evidence in an append-only,
hash-chained ledger (`approval/decisions.jsonl`). The coordinator then runs `state.ps1
decide`, which checks the evidence against the current plan and against the session
transcript (it must be a prompt Claude Code recorded as typed, with the same text). The
coordinator cannot produce evidence: hooks deny its writes to approval files, state, and
history, and background-agent notifications or prompts that only mention a command are
never recorded. Any later change to the plan voids the approval; rejection is final.

`REVISE PLAN` is also how you ask for changes to a validated plan, in the same session or
later with `/prepare-interview revise <run-id>`. Only the plan reopens: the
`study-planner` revises it from the validated research using your words, and the plan is
validated again. Research is not re-run.

**Guardrail hooks.** PreToolUse enforces artifact ownership (only the owning agent, only
while its step runs), denies direct writes to state, version history, approval evidence,
and the guide, and, while a run is open, limits shell commands to `state.ps1`, the test
runner, and read-only git. PostToolUse runs the integrity check after relevant writes and
reports violations without repairing anything. The hooks are pinned by hash; after editing
a hook or `state.ps1`, run `! pwsh -NoProfile -File scripts/pin-hooks.ps1` and restart
Claude Code. They are guardrails inside Claude Code, **not an OS security boundary** (see
Known limitations).

**Gate-failure retries vs. requested revisions** (CLAUDE.md §6.2):
- **A retry** is automatic. It happens when a gate fails or a validator finds a
  **blocking** problem, and it counts against the owner's **3 attempts per version**.
- **A revision** is a change **you** ask for to a plan that already passed validation. It
  can start from an advisory finding you pick, but advisory findings never start one by
  themselves. Revisions are recorded separately (`state.json` → `revisions`) and limited to
  **3 per plan per run**. Each revised version gets its own 3 attempts, and the earlier
  retry history is kept as it was.

**Accepted versions and integrity** (CLAUDE.md §6.4): every artifact that passes is
recorded with a version number and hash, and copied to `versions/`. If a passed artifact
is edited outside the workflow, the run is **blocked**. The edit is never accepted or
passed on to later steps. To continue, restore the accepted version, or discard the
artifact so its owner regenerates it (`state.ps1 resolve`).

### Hooks verified with real Claude Code sessions (2026-10-13, Phase 4B)

Headless `claude -p` sessions (Claude Code 2.1.296, Windows 11, PowerShell 7.6) ran in an
isolated scratch copy of the project, with the hooks pinned and two validated fixture runs.
The repository and its real runs were not used.

- **Capture and origin:** `APPROVE PLAN <run> <hash12>` was recorded by the hook, and the
  model ran `decide` as the hook instructed. With the default policy (`typed` only), `decide`
  refused it, because the transcript records a `claude -p` prompt as `promptSource: sdk`.
  The transcript text matched the captured hash. With the scratch policy set to also accept
  `sdk` (test only), the same flow approved the plan.
- **Notifications:** a background subagent whose reply was the exact approval phrase
  produced a `system / task_notification` prompt; nothing was recorded.
- **REVISE PLAN:** captured, applied by `decide`, and turned into revision `rev-001` with the
  user's words and a reference to its evidence.
- **Bypass attempts in bypassPermissions mode:** writes to `approval.json`,
  `approval/decisions.jsonl`, `plan.md` (by the coordinator), and `guide.html`, a shell
  redirect into an approval file, `pwsh -Command "& ./scripts/state.ps1 decide"`, a nested
  `claude -p`, and `ls` while a run was open were all denied. `state.ps1 start -Step render`
  was allowed by the hook and refused by `state.ps1`. No run file changed.
- **Ownership with real `agent_type`:** the `study-planner` subagent wrote `plan.md` while
  the plan step was running; its write to `research/data.md` was denied.
- **PostToolUse:** after `research/dotnet.md` was edited outside Claude Code, the next
  `git status` call reported the integrity violation; the run became `blocked`, and the
  file was left as it was.
- **Pinning:** with one hook file changed, a `Write` call was denied and a `REJECT PLAN`
  prompt recorded nothing.

Interactive typing (`promptSource: typed`) was checked by hand in the Phase 4.0 spike, not in
these automated sessions.

### Verified plan revision with live agents (2026-10-12, Phase 3B)

One real `/prepare-interview` run went from requirements through plan validation. The
user then requested a revision of the validated plan. As before, the run data stays local
and is not committed.

- **Request:** the user picked the 4 advisory findings from plan validation and confirmed
  the revision explicitly. `state.ps1 verify` reported no integrity violations, and
  `state.ps1 revise` opened `rev-001` with `source: advisory`. It archived the request in
  `revisions/` and invalidated only `plan-validation`.
- **Regeneration:** `study-planner` was invoked again with the original plan snapshot and
  the confirmed feedback. The revised plan passed the deterministic gate on attempt 1 as
  version 2.
- **Re-validation:** `quality-validator` was invoked again in plan mode with the revision
  feedback. It passed on attempt 1 with 0 blocking findings, and the revision closed as
  `completed` with `result_version: 2`.
- **Not re-run:** research and the coverage gate stayed `passed` and untouched. No new
  sources were fetched.
- **Preserved:** version 1 stayed in `versions/plan-v1.md` beside `versions/plan-v2.md`.
  The step history, the archived request, and every validator report in
  `validation/history/` were kept.
- **Budget:** the confirmed 150-minute budget was kept exactly. The plan still has five
  study days of 30 minutes each.
- **Remaining:** 3 non-blocking advisory findings, offered as optional further revisions.
- **Not exercised by this run:** no integrity violation occurred, so `resolve`
  (`restore`/`discard`) is still tested by fixtures only. No gate failed during the
  revision, so revision retries are untested with live agents.

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
policy. Neither could be fixed in that run, because a passed plan could not be reopened in
Phase 3A. Phase 3B adds requested revisions for exactly this case; the run itself was not
modified.

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
- **Revisions have one real run; integrity resolution has none.** One live revision
  completed on its first attempt (see above). Revision retries, a failed revision, and
  integrity violations with `resolve` are tested with fixtures only.
- **Revision authorization is recorded, not proven.** `state.ps1` requires an explicit
  request from the user that quotes their confirmation, but it cannot verify that the user
  typed it. The coordinator prompt is the enforcement.
- **Only the plan can be revised**, one revision at a time, and only after it passed
  validation. Changes to confirmed requirements, or anything needing new research, are not
  possible as a revision. A revision that runs out of attempts fails the run; the previous
  version is kept in `versions/`, but there is no rollback action.
- **Advisory findings are never acted on automatically.** They are offered as suggested
  revisions; only your request opens one.
- **Integrity covers each step's main artifact only.** Validator summaries,
  `confirmed-input.md`, and `research-selection.json` are not hash-checked. Runs created
  before Phase 3B have no version snapshots, so `restore` is unavailable for them.
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
- **The guide renders the planner's Markdown subset** (headings, tables, lists, code,
  bold, links); anything else appears as escaped text. One HTML guide per approval; no PDF
  or other formats. No real run has rendered a guide yet (fixture tests only).
- **Pinned files and line endings.** The hook pins hash exact bytes. A clone that checks
  the pinned files out with CRLF line endings (for example `core.autocrlf=true`) must run
  `pin-hooks.ps1` once, or its tool calls are denied.
- **Hooks are guardrails, not an OS security boundary** (CLAUDE.md §12.5). They see only
  Claude Code's own prompts and tool calls. `!` commands, other terminals and editors, and
  sessions started without the project's hooks can write any file you can, including the
  decision ledger and the session transcript.
- **The origin check is not proof of identity.** `decide` checks that Claude Code recorded
  your prompt as typed input with the same text. That ties the decision to a prompt in the
  session; it does not prove who typed it, and it does not distinguish pasted text.
- **Strict shell mode** applies while any run is open (not completed, rejected, or failed,
  and updated within 24 hours): the model may run only `state.ps1`, the test runner, and
  read-only git. Use `!` for anything else. An abandoned run stops restricting the shell
  after 24 hours.
- **Editing a hook or `state.ps1` blocks the session's tools** until you re-pin
  (`! pwsh -NoProfile -File scripts/pin-hooks.ps1`) and restart Claude Code. That is the
  intended fail-closed behavior.
- **Ledger recovery is partly manual.** A malformed unconsumed entry blocks `decide` until
  `state.ps1 quarantine-ledger` moves it (and anything after it) aside. Damaged consumed
  entries can only be restored by hand.
- **The plan gate parses only its own format.** It reads the schedule table, front matter,
  and URLs in the exact format the `study-planner` prompt defines. A differently formatted
  but valid plan fails the gate and is retried.
- `state.ps1` itself refuses to start or pass the `render` step without a valid approval,
  independently of the hooks.
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
pwsh -NoProfile -File tests/run-tests.ps1 -SkipConcurrency   # sequential tests only
pwsh -NoProfile -File tests/run-tests.ps1 -SkipConcurrency -Filter quarantine   # tests whose name matches a regex
pwsh -NoProfile -File tests/run-tests.ps1 -Iterations 25     # heavier concurrency stress
pwsh -NoProfile -File tests/run-tests.ps1 -SensitivityCheck  # also prove the tests catch lost updates
pwsh -NoProfile -File tests/run-tests.ps1 -KeepTestRoot      # keep the temp directory for inspection
```

The exit code is 0 when every test passes. Every run works in a fresh directory under the
system temp folder, passed to `state.ps1` with `-RunsRoot`, and deletes it at the end.
Nothing is written to `runs/`.

- **Phase 5 render tests (5, `tests/render.tests.ps1`):** an approved plan renders with its
  schedule, exercises, interview questions, sources, and navigation, and the run completes
  without changing any other artifact; rendering is refused without an approval (including
  a model-written `approval.json`), after a revision voided the approval, and after a manual
  plan edit; hostile plan text (script and image tags, event handlers, `javascript:` and
  `data:` links, a quote inside a URL) is escaped; the guide's hash is recorded, a second
  render is refused, direct writes and chained renderer commands are denied, and tampering
  is detected and restorable.
- **Phase 4B hook tests (16, `tests/hooks.tests.ps1`):** each hook runs exactly as Claude
  Code runs it (hook-input JSON on stdin). These cover:
  - UserPromptSubmit: an exact typed approval recorded and then applied by `decide` after the
    transcript check; background-agent notifications, agent messages, and prompts that only
    mention a decision never recorded; malformed commands, another plan's hash, an unknown
    run, and an undecidable plan blocked with nothing recorded; REVISE and REJECT captured;
    a decision captured before the plan changed refused as stale,
  - `decide` refusing evidence whose transcript entry is a system notification, an `sdk`
    prompt, different text, missing, or in a missing transcript,
  - `revise` requiring the user's REVISE evidence and using the user's words,
  - PreToolUse: denied writes to state, history, approval evidence, the guide, and
    transcripts; ownership by `agent_type` and running step; `ask` for configuration and
    scripts; writes through a junction; the shell allowlist, nested sessions, encoded
    commands, protected paths, and strict mode,
  - PostToolUse: integrity violations and an unauthorized `guide.html` reported, nothing
    repaired or deleted; a model-written `approval.json` authorizes nothing; a clean check
    never writes `state.json` or refreshes `updated_at`, and a new violation is recorded once;
    an old schema-1 run without a plan is checked, and a failed check is not reported as a
    violation,
  - fail-closed handling of malformed input, and the pinned launchers (a changed hook file
    denies tools and records no decision; re-pinning accepts it).
- **Phase 4A tests (14, `tests/state.approval.tests.ps1`):** decision evidence is written
  by the test-only helper `Add-TestOnlyLedgerEntry` (production has no ledger writer). These
  cover:
  - no evidence, a forged `approval.json`, and a `state.json` edited to "approved",
  - a valid approval, then render refused or passed by the approved hash,
  - 17 forged or malformed ledgers (source, run, chain, sequence, IDs, hashes, schema,
    feedback rules, non-JSON lines, a valid entry followed by a broken one), never consumed,
  - stale evidence (another plan hash, another version, a plan not yet validated) and
    replayed evidence, consumed and refused,
  - rejection (final), request changes (a revision with your feedback, then a new approval),
  - voiding by a revision or discard, versus a manual edit (blocked, restore revalidates),
  - tampering with `approval.json` or consumed ledger entries,
  - upgrading an older run: only the two steps are added; every existing step, hash, attempt
    count, history entry, and file is unchanged,
  - `quarantine-ledger`: only the malformed suffix moves, valid and consumed entries stay
    usable, a valid ledger is refused, repeats are idempotent, an interrupted quarantine
    resumes, and a damaged consumed history is refused.

  A mutation check (not part of the suite) removed one protection at a time from a copy of
  `state.ps1`; the tests detected all 9 mutants.
- **Phase 3B tests (10, `tests/state.revision.tests.ps1`):** agent outputs are fixtures.
  These cover:
  - revising a passed plan: only the planner reopens, plan validation is invalidated and
    re-run, research and coverage are unchanged (state entries and file hashes), and the
    new version is recorded with its hash and snapshot,
  - rejected revisions: requested by an agent or the coordinator, no confirmation, no
    feedback or reason, unknown or missing advisory IDs, wrong step, not-yet-validated plan,
    non-revisable step. All of these change nothing,
  - multiple sequential revisions (unique IDs, one open at a time, an advisory finding
    picked by the user),
  - a revised plan failing its gate and its validation, retried on its own budget,
  - gate-failure history kept separate from revision history,
  - a research finding during a revision (whole-chain invalidation and revalidation),
  - the revision limit, and a revision that runs out of attempts,
  - manual edits to a passed plan or research artifact (blocked, then restored or
    discarded),
  - URLs containing apostrophes.
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
  - downstream invalidation after a re-run upstream step, and stale attempts,
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

Last full run (2026-10-13, Phase 5, Windows 11, PowerShell 7.6, `-Iterations 5`): 97 tests.

- **95 of 97 passed** in about 26 minutes. The 2 failures were test fixtures, not product
  code: a PostToolUse test assumed no other run in the shared test directory reported a
  violation, and the pinning test did not copy the newly pinned `render-guide.ps1`. Both
  tests were fixed, and all **89 sequential tests then passed** (`-SkipConcurrency`, about
  23 minutes). The 8 concurrency tests passed in the full run and are unaffected by those
  test-only changes.
- **Overlap:** there were 60 concurrent batches. In all 60, every operation overlapped
  every other one, and start times were spread by 2 ms on average (17 ms at most).
- **Readers:** unlocked readers parsed `state.json` 9,513 times and saw 0 invalid reads
  (11 reads hit a transient file-sharing error while opening the file; those are counted
  separately and the reader just reads again on its next loop).

The concurrency tests exercise the research steps. The Phase 3A and 3B steps run one at a
time by design, so they are tested sequentially.

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
| `.claude/commands/`| `/prepare-interview` command (requirements through the HTML guide) |
| `.claude/skills/`  | Skills: `artifact-validator`, `html-guide-builder` |
| `.claude/hooks/`   | Guardrail hooks: UserPromptSubmit, PreToolUse, PostToolUse |
| `scripts/`         | Deterministic helpers (`state.ps1`, `render-guide.ps1`, `pin-hooks.ps1`) |
| `tests/`           | Test suite (`run-tests.ps1`): state, approval, hooks, rendering |
| `artifacts/`       | Shared reference material (planned)         |
| `runs/`            | Per-run state and outputs; `runs/demo-*/` is committed |
| `templates/`       | Final HTML templates (planned)              |
