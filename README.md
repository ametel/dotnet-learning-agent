# dotnet-learning-agent

An educational multi-agent workflow built on [Claude Code](https://claude.com/claude-code)
that creates a **personalized .NET interview preparation guide**.

The planned entry point is a `/prepare-interview` slash command. A coordinator agent gathers
your requirements, then dynamically selects specialized subagents to research the relevant
.NET topics with external tools. It assembles a personalized learning plan, validates every
intermediate artifact, asks for your approval, and renders the final guide as HTML.

## Status

🚧 **Implementation in progress (Phase 2C: stabilization).** `/prepare-interview` gathers and confirms your
requirements, then has the `requirements-formalizer` subagent write
`runs/<run-id>/requirements.md`. It then selects only the relevant research agents
(`dotnet-researcher`, `data-researcher`, `architecture-researcher`), launches them in
parallel to write `runs/<run-id>/research/<area>.md` from web sources, and stops.
Study-plan synthesis, approval, and HTML generation are not implemented yet.

### Verified end-to-end run (2026-10-12)

One real `/prepare-interview` run exercised the whole Phase 2B path. The run data stays
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

- There is no study-plan synthesis agent yet, so the run stops after research.
- There is no global coverage gate across agents. Each research artifact is checked only
  against its own assigned topics, so a topic that falls between two agents can go
  uncovered. The verified run had one such case: EF Core optimistic concurrency.
- Downstream invalidation and resume are not implemented. `state.ps1` detects stale
  inputs: it refuses to start research when `requirements.md` or `confirmed-input.md`
  changed, and a `complete` fails if an input changed during the attempt. But nothing yet
  resets stale steps to `pending` or resumes a run (CLAUDE.md §5.2, §7).
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
pwsh -NoProfile -File tests/run-tests.ps1 -SkipConcurrency   # sequential tests only (~100 s)
pwsh -NoProfile -File tests/run-tests.ps1 -Iterations 25     # heavier concurrency stress
pwsh -NoProfile -File tests/run-tests.ps1 -SensitivityCheck  # also prove the tests catch lost updates
pwsh -NoProfile -File tests/run-tests.ps1 -KeepTestRoot      # keep the temp directory for inspection
```

The exit code is 0 when every test passes. Every run works in a fresh directory under the
system temp folder, passed to `state.ps1` with `-RunsRoot`, and deletes it at the end.
Nothing is written to `runs/`.

- **Sequential tests (27):** these cover:
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

Last full run (2026-10-12, Windows 11, PowerShell 7.6, `-Iterations 10 -SensitivityCheck`):

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
| `.claude/agents/`  | Subagent definitions (requirements + 3 research agents) |
| `.claude/commands/`| `/prepare-interview` command (Phase 2B scope) |
| `.claude/skills/`  | Reusable skills (planned)                   |
| `.claude/hooks/`   | Guardrail hooks (planned)                   |
| `scripts/`         | Deterministic helpers (`state.ps1`)          |
| `tests/`           | Test suite for `state.ps1` (`run-tests.ps1`) |
| `artifacts/`       | Shared reference material (planned)         |
| `runs/`            | Per-run state and outputs; `runs/demo-*/` is committed |
| `templates/`       | Final HTML templates (planned)              |
