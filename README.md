# dotnet-learning-agent

An educational multi-agent workflow built on [Claude Code](https://claude.com/claude-code)
that creates a **personalized .NET interview preparation guide**.

The planned entry point is a `/prepare-interview` slash command. A coordinator agent gathers
your requirements, then dynamically selects specialized subagents to research the relevant
.NET topics with external tools. It assembles a personalized learning plan, validates every
intermediate artifact, asks for your approval, and renders the final guide as HTML.

## Status

🚧 **Implementation in progress.** Only Phase 1 is complete: the repository structure and the
architecture documentation. The agents, the slash command, skills, hooks, and MCP
configuration have not been implemented yet, so the workflow cannot be run.

See [CLAUDE.md](CLAUDE.md) for the architecture and design rules.

## Layout

| Path               | Purpose                                     |
|--------------------|---------------------------------------------|
| `.claude/agents/`  | Subagent definitions (planned)              |
| `.claude/commands/`| `/prepare-interview` command (planned)      |
| `.claude/skills/`  | Reusable skills (planned)                   |
| `.claude/hooks/`   | Guardrail hooks (planned)                   |
| `scripts/`         | Deterministic helper scripts (planned)      |
| `artifacts/`       | Shared reference material (planned)         |
| `runs/`            | Per-run state and outputs; `runs/demo-*/` is committed |
| `templates/`       | Final HTML templates (planned)              |
