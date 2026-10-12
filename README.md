# dotnet-learning-agent

An educational multi-agent workflow built on [Claude Code](https://claude.com/claude-code)
that creates a **personalized .NET interview preparation guide**.

The planned entry point is a `/prepare-interview` slash command. A coordinator agent gathers
your requirements, then dynamically selects specialized subagents to research the relevant
.NET topics with external tools. It assembles a personalized learning plan, validates every
intermediate artifact, asks for your approval, and renders the final guide as HTML.

## Status

🚧 **Implementation in progress (Phase 2A).** `/prepare-interview` gathers and confirms your
requirements. It then delegates to the `requirements-formalizer` subagent, which writes
`runs/<run-id>/requirements.md`, and stops. Research, planning, approval, and HTML
generation are not implemented yet.

Requires [Claude Code](https://claude.com/claude-code) and PowerShell 7+ (`pwsh`) for the
state helper `scripts/state.ps1`.

```
/prepare-interview Senior backend .NET developer, interview in 3 weeks, ~8 h/week, weak on concurrency and EF Core performance
```

See [CLAUDE.md](CLAUDE.md) for the architecture and design rules.

## Layout

| Path               | Purpose                                     |
|--------------------|---------------------------------------------|
| `.claude/agents/`  | Subagent definitions (`requirements-formalizer`) |
| `.claude/commands/`| `/prepare-interview` command (Phase 2A scope) |
| `.claude/skills/`  | Reusable skills (planned)                   |
| `.claude/hooks/`   | Guardrail hooks (planned)                   |
| `scripts/`         | Deterministic helpers (`state.ps1`)          |
| `artifacts/`       | Shared reference material (planned)         |
| `runs/`            | Per-run state and outputs; `runs/demo-*/` is committed |
| `templates/`       | Final HTML templates (planned)              |
