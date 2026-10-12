# dotnet-learning-agent

An educational multi-agent workflow built on [Claude Code](https://claude.com/claude-code)
that creates a **personalized .NET interview preparation guide**.

The planned entry point is a `/prepare-interview` slash command. A coordinator agent gathers
your requirements, then dynamically selects specialized subagents to research the relevant
.NET topics with external tools. It assembles a personalized learning plan, validates every
intermediate artifact, asks for your approval, and renders the final guide as HTML.

## Status

🚧 **Implementation in progress (Phase 2B).** `/prepare-interview` gathers and confirms your
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
- Downstream invalidation and resume are not implemented. `state.json` records input
  hashes, and `state.ps1` refuses to start research on a changed `requirements.md`, but
  nothing yet resets stale steps or resumes a run (CLAUDE.md §5.2, §7).
- No hooks enforce artifact ownership or the approval-before-HTML rule. The coordinator
  prompt and the agents' instructions are the only enforcement.

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
| `artifacts/`       | Shared reference material (planned)         |
| `runs/`            | Per-run state and outputs; `runs/demo-*/` is committed |
| `templates/`       | Final HTML templates (planned)              |
