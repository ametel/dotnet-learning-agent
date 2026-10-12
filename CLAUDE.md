# CLAUDE.md — dotnet-learning-agent

This file is the architectural contract for this repository. Claude Code must follow it
when implementing or running any part of the workflow.

> **Status:** Phase 2B. Implemented: `/prepare-interview` (requirements, then dynamic
> selection and parallel execution of research agents), the `requirements-formalizer`,
> `dotnet-researcher`, `data-researcher`, and `architecture-researcher` subagents, and
> `scripts/state.ps1` (state init/select/update with locking, which requires PowerShell 7+).
> The Microsoft Learn MCP server is configured in `.mcp.json` (§9.1). Plan synthesis, plan
> validation, approval, HTML, skills, and hooks are **not implemented yet**. Parallel
> research with real Microsoft Learn MCP calls was exercised end to end on 2026-10-12
> (see README). Not implemented yet: a global cross-agent coverage gate, downstream
> invalidation and resume (§5.2, §7 describe the target design), and hooks that enforce
> artifact ownership and approval.
> Do not describe anything as working until it exists and has been exercised.

---

## 1. Purpose and scope

`dotnet-learning-agent` is an educational multi-agent workflow built on Claude Code. It
produces a **personalized .NET interview preparation guide**.

The user starts it with the `/prepare-interview` slash command. The workflow:

1. gathers requirements (target role, seniority, timeline, known strengths and gaps, target
   company or stack),
2. dynamically selects the specialized subagents that are relevant,
3. researches using external tools (web and MCP servers),
4. generates a personalized learning plan,
5. validates every intermediate artifact against quality gates,
6. asks for **explicit human approval**, and
7. renders a final HTML learning guide.

**In scope:** .NET / C# interview preparation (language, runtime, ASP.NET Core, data access,
architecture, testing, cloud, system design, behavioral prep).
**Out of scope:** general career coaching, job applications, and storing personal data
beyond what one run needs.

---

## 2. Architecture: hub-and-spoke

```
                        ┌──────────────────────┐
           user ◄──────►│  Coordinator (hub)   │◄──── runs/<run-id>/state.json
                        │  /prepare-interview  │
                        └──────────┬───────────┘
              ┌──────────────┬─────┴────────┬───────────────┐
              ▼              ▼              ▼               ▼
        requirements     research       plan author      validator
          spoke          spokes (N)       spoke            spoke
```

- The **coordinator** is the only hub. It is the main Claude Code session driven by the
  `/prepare-interview` command.
- **Subagents** are spokes, defined in `.claude/agents/`. They never call each other.
  All communication goes through the coordinator and through artifacts on disk.
- Shared state lives in files (`runs/<run-id>/`), never only in conversation memory.

### 2.1 Coordinator responsibilities

The coordinator:

- talks to the user (requirements questions, approval prompt, final summary),
- creates and owns the run directory and `state.json`,
- decides which subagents to run, and whether in parallel or in sequence,
- passes each subagent an explicit input (file paths plus a focused task) and the
  expected output path,
- runs the quality gates on each returned artifact and decides between accept, retry,
  and fail,
- records every step transition in `state.json` so the run can be resumed,
- asks for human approval and records the decision,
- triggers final HTML generation only after approval.

The coordinator does **not** do specialist work itself, such as writing research notes or
authoring plan content. If it is tempted to, that is a sign a subagent is missing.

### 2.2 Subagent responsibilities

Each subagent:

- has one narrow responsibility and a minimal tool set,
- reads only the inputs the coordinator named,
- writes only to its assigned output artifact path(s),
- returns a short summary to the coordinator (not the full artifact content),
- does not talk to the user, does not edit `state.json`, and does not call other
  subagents.

### 2.3 Separation of concerns

| Concern                         | Coordinator | Subagent |
|---------------------------------|:-----------:|:--------:|
| User interaction                | ✅          | ❌       |
| Choosing which agents run       | ✅          | ❌       |
| Writing `state.json`            | ✅          | ❌       |
| Domain research / content       | ❌          | ✅       |
| Writing its own artifact        | ❌          | ✅       |
| Validating artifacts / retries  | ✅ (may delegate checks to a validator spoke) | ❌ |
| Approval and final rendering    | ✅          | ❌       |

---

## 3. Dynamic subagent selection

Subagents are chosen **from the gathered requirements**, not from a fixed list. For example:

- A backend role pulls in ASP.NET Core, data access (EF Core, SQL), and system-design
  research.
- A cloud-heavy role adds Azure / cloud-native research.
- A senior or lead role adds architecture and behavioral/leadership topics.
- Topics the user says they have already mastered are skipped or reduced.

The coordinator writes the selection and a one-line reason for each agent into
`state.json` (`selected_agents`). That way the choice is auditable and survives a resume.

### 3.1 Research agents (implemented)

| Agent | Area | Artifact |
|---|---|---|
| `dotnet-researcher` | C#, .NET runtime, async/await, concurrency, ASP.NET Core | `research/dotnet.md` |
| `data-researcher` | EF Core, SQL, query optimization, data access | `research/data.md` |
| `architecture-researcher` | System design, architecture, distributed systems | `research/architecture.md` |

- The coordinator maps each researchable gap or requested topic to **exactly one** agent.
  An agent is selected only if at least one topic maps to it. Strengths alone never
  select an agent.
- The selection is written to `research-selection.json` and recorded with
  `state.ps1 select`. That records `research.selected_agents` (agent, topics, reason) and
  `research.not_selected` (agent, reason), and creates one `research-<area>` step per
  selected agent. Every registered agent must appear in one of the two lists.
- The agent registry (agent → area → artifact path) lives in `scripts/state.ps1`. Adding a
  research agent means adding it there, in `.claude/agents/`, and in the coordinator's
  selection table.

---

## 4. Execution rules: sequential vs. parallel

**Sequential** (each step depends on the one before):

1. Requirements gathering → `requirements.md`
2. Agent selection (coordinator)
3. Research (see below)
4. Learning-plan synthesis (needs all research)
5. Plan validation
6. Human approval
7. HTML generation

**Parallel:** independent research subagents (one per topic area) may run at the same
time. They must write to distinct output paths and must not read each other's output.
The coordinator launches them with several `Agent` tool calls in **one** message, and the
research phase ends only when every selected step is `passed` or out of attempts. Each
step is gated and retried on its own: a failure in one never re-runs, overwrites, or
blocks another. `state.ps1` holds a per-run lock (`state.lock`) around each state update,
so parallel completions cannot lose writes.

**Rule of thumb:** run in parallel only when the tasks share no inputs that another task
in the same batch produces, and write to disjoint paths. Otherwise run them in sequence.

### 4.1 Open questions do not block progress

- `requirements.md` tags each open question as `[blocking]` or `[non-blocking]`, and records
  the count of blocking ones in its front matter (`blocking_open_questions`).
- **Blocking** questions are essential fields (role or stack, seniority, timeline, time
  availability, knowledge gaps) that are `Unspecified`. If any exist, the coordinator shows
  them to the user before planning and may continue with labeled assumptions only if the
  user agrees.
- **Non-blocking** questions are unanswered optional fields, vague-but-present values, and
  derived values. They never stop the workflow. Later phases proceed with the default
  assumption stated in the artifact and repeat any assumption that influences their output.
  The coordinator does not re-ask them before planning, but the user may answer them at any
  time. An answer changes `confirmed-input.md` and triggers invalidation (§5.2).

---

## 5. Artifact ownership

Every artifact has exactly **one owner**, the only actor allowed to write it.
Everyone else treats it as read-only.

Planned layout of a run (names may be refined during implementation):

```
runs/<run-id>/
  state.json                 # owner: coordinator (written via scripts/state.ps1)
  confirmed-input.md         # owner: coordinator (requirements exactly as the user confirmed them)
  requirements.md            # owner: requirements-formalizer subagent
  research-selection.json    # owner: coordinator (selected / not-selected agents with reasons)
  research/dotnet.md         # owner: dotnet-researcher
  research/data.md           # owner: data-researcher
  research/architecture.md   # owner: architecture-researcher
  plan.md                    # owner: plan-author subagent
  validation/<artifact>.json # owner: validator (subagent or script)
  approval.json              # owner: coordinator (records the human decision)
  guide.html                 # owner: HTML renderer, written only after approval
```

### 5.1 Artifact formats

- **Markdown** for human-readable workflow artifacts: requirements, research notes, and the
  learning plan. People review these, and the approval step shows them to the user.
- **JSON** for machine-readable state and metadata: `state.json`, `validation/*.json`,
  and `approval.json`. Scripts and hooks read these, so they must parse cleanly.
- **HTML** only for the final rendered guide.

If a Markdown artifact needs fields a machine can check (for example, the list of topics it
covers), it puts them in a small YAML front-matter block rather than in a separate JSON file.

### 5.2 Dependency invalidation

Artifacts form a dependency chain:

```
confirmed-input.md → requirements.md → research/<area>.md → plan.md → validation/plan.json → approval.json → guide.html
```

- **Changing an upstream artifact invalidates every artifact downstream of it.** If
  `requirements.md` changes, all research, the plan, the validations, the approval, and the
  guide are stale. If one `research/<area>.md` changes, the plan and everything after it are
  stale; research on other topics is not.
- `state.json` records the content hash of each input an artifact was built from. On resume,
  or after any change, the coordinator compares hashes and resets stale steps to `pending`.
- A stale artifact must never be used as an input, even if it passed its gate before.
- Invalidation is not a failed attempt. An artifact invalidated by an upstream change gets a
  fresh budget of 3 attempts for its new inputs.

- `artifacts/` holds shared, run-independent reference material (for example, curated
  topic catalogs). Runs read it. It is not a dumping ground for run output.
- `templates/` holds the HTML/Markdown templates used for final rendering.
- `scripts/` holds deterministic helpers (validation, rendering, state checks).

When a retry happens, the owner overwrites its own artifact. The previous attempt's
validation result is kept in `validation/` for traceability.

---

## 6. Quality gates and targeted retries

Every artifact passes a quality gate before the next step consumes it. Gates check:

- **Structure:** required fields and sections exist, and JSON parses.
- **Coverage:** every selected topic and every stated gap is addressed.
- **Grounding:** research claims carry sources (URLs or doc references).
- **Personalization:** content reflects the stated role, seniority, and timeline.

Retry policy:

- Retries are **targeted**. Only the subagent that owns the failing artifact is re-run,
  and it receives the specific gate failures as feedback. Upstream work is not redone.
- **Maximum 3 attempts per artifact** (the initial attempt plus 2 retries).
- After the 3rd failure the coordinator stops that branch, records the failure in
  `state.json`, and reports it to the user. It does not silently continue with a bad
  artifact.
- Attempt counts are persisted in `state.json`, so a resume does not reset them.

---

## 7. Workflow persistence and resume

- Each invocation gets a run directory `runs/<run-id>/` (for example,
  `runs/2026-10-12-senior-backend/`).
- `state.json` is the source of truth. At minimum it records: the run ID, the current
  step, the status of each step (`pending` / `running` / `passed` / `failed`), the
  selected agents, the attempt counts, the input hashes of each artifact (§5.2), and the
  approval status.
- The coordinator updates `state.json` **before and after** every step.
- On resume, the coordinator reads `state.json`, skips steps already marked `passed`
  whose artifacts still exist, validate, and are not stale (§5.2), and continues from the
  first incomplete step.
- A crash or interruption must never require starting over from requirements.

---

## 8. Human approval before final HTML

- After the plan passes validation, the coordinator shows the user a concise summary of
  the plan and asks for explicit approval: approve, request changes, or abort.
- The decision and any feedback go to `approval.json`.
- "Request changes" sends a targeted revision to the plan owner. This counts toward that
  artifact's retry budget only if it is a gate failure; user-requested revisions are
  tracked separately.
- **Approval is tied to the exact plan content.** `approval.json` records the SHA-256 hash
  of the `plan.md` the user approved (plus a plan version number for readability).
- Before rendering, the coordinator recomputes the hash of the current `plan.md`. If it
  differs from the approved hash, the approval is void: the plan must be re-validated and
  re-approved. Any edit to the plan after approval, however small, invalidates the approval
  (see §5.2).
- **No HTML is generated without an approval recorded on disk that matches the current plan
  hash.** Later phases may enforce this with a hook. Until then it is a rule the coordinator
  must follow.

---

## 9. External research and MCP

- Research subagents must use external tools (web search/fetch and/or MCP servers) rather
  than relying only on model memory. Official sources (Microsoft Learn, the .NET docs,
  release notes) are preferred.
- Every research artifact lists the sources it used. Unsourced claims fail the grounding
  gate.
- MCP servers are configured in the project-level `.mcp.json`. Credentials are **never**
  committed. They come from the environment or from local, git-ignored files. The
  Microsoft Learn server needs no credentials.
- If an external tool is unavailable, the subagent must say so rather than fabricate
  sources. If **no** research tool works (MCP, `WebSearch`, and `WebFetch` all failing), a
  research agent writes nothing and replies `FAILED: TOOLS_UNAVAILABLE`. The coordinator
  records that as a non-retryable failure (`state.ps1 fail -NoRetry`). Partial outages are
  listed under the artifact's *Gaps and Limitations*.
- Research gate (deterministic): required headings, one `### <topic>` per assigned topic,
  at least 3 distinct URLs under `## Sources`, and at least one `learn.microsoft.com` URL
  for the `dotnet` and `data` areas. The coordinator also spot-checks up to 2 URLs per
  artifact (Microsoft Learn URLs via `microsoft_docs_fetch`).

### 9.1 Microsoft Learn MCP server

- Config: `.mcp.json` declares server `microsoft-learn`, an HTTP server at
  `https://learn.microsoft.com/api/mcp`. It is public and needs no authentication.
- Tools discovered (exact names):

  | Tool | Purpose |
  |---|---|
  | `mcp__microsoft-learn__microsoft_docs_search` | Search official Microsoft/Azure docs; returns title, excerpt, and `contentUrl` |
  | `mcp__microsoft-learn__microsoft_docs_fetch` | Fetch a Microsoft Learn page as Markdown |
  | `mcp__microsoft-learn__microsoft_code_sample_search` | Search official Microsoft code samples |

- All three research agents list these tools in their `tools:` frontmatter, alongside
  `WebSearch`/`WebFetch` for non-Microsoft sources.
- Project `.mcp.json` servers need **per-user approval** before Claude Code connects. Approve
  the server when `claude` prompts, or add `"enabledMcpjsonServers": ["microsoft-learn"]` to
  your own `.claude/settings.local.json` (git-ignored). The shared settings deliberately do
  not auto-approve MCP servers.

### 9.2 Research tool permissions

`.claude/settings.json` pre-approves only what background research agents need, because
background subagents cannot answer permission prompts. Unapproved calls are denied, not
asked.

| Allowed without a prompt | Why |
|---|---|
| The 3 `mcp__microsoft-learn__*` tools | Read-only search and fetch of official docs |
| `WebSearch` | Finds non-Microsoft sources. Permission rules cannot scope it by domain. |
| `WebFetch(domain:...)` for `learn.microsoft.com`, `devblogs.microsoft.com`, `github.com`, `martinfowler.com`, `microservices.io` | Curated official and expert sources |
| `Bash(pwsh -NoProfile -File scripts/state.ps1:*)` | The coordinator's state helper |

**Limitation:** a background research agent cannot fetch pages on any other domain. Those
`WebFetch` calls are denied. The agent must record the denial under *Gaps and Limitations*
and must not cite what it could not read. To widen access, add specific
`WebFetch(domain:<host>)` rules, never a bare `WebFetch`. Large tool results (e.g. a long
`microsoft_docs_fetch` page) are saved by Claude Code to a file under `~/.claude/projects/`,
and agents may read those files.

### 9.3 Verification and troubleshooting

```
claude mcp get microsoft-learn     # expect: Status: ✔ Connected
claude mcp list                    # health-checks all configured servers
```

Inside a session, `/mcp` shows the server and its tools.

| Symptom | Fix |
|---|---|
| `⏸ Pending approval` | Run `claude` in the repo and approve the server, or add `enabledMcpjsonServers` to `.claude/settings.local.json` |
| `✘ Failed to connect` | Check network or proxy access to `https://learn.microsoft.com/api/mcp`. Corporate proxies may need `HTTPS_PROXY`. |
| Research agent reports MCP tools missing | The session started before `.mcp.json` existed or before approval. Start a new session. |
| `WebFetch` denied in a research artifact's *Gaps* | The domain is not in the allowlist. That is expected. Add a specific domain rule if needed. |
| Server was renamed | Tool names change with it (`mcp__<server>__<tool>`). Update the agents' `tools:` lists, `settings.json`, and the command's `allowed-tools`. |

---

## 10. Repository layout

```
.claude/agents/     subagent definitions              (requirements + 3 research agents)
.claude/commands/   /prepare-interview command        (Phase 2B scope)
.claude/skills/     reusable skills                   (planned)
.claude/hooks/      guardrail hooks                   (planned)
scripts/            deterministic helpers             (state.ps1)
artifacts/          shared reference material         (planned)
runs/               per-run state and outputs
templates/          final HTML templates              (planned)
```

### Committed demonstration runs

Three demonstration runs will eventually be committed. They must live in directories named
`runs/demo-*/`. `.gitignore` always tracks those, including their logs. Any other directory
under `runs/` is treated as local and is ignored.

---

## 11. Working conventions

- Prefer simple, maintainable designs: plain files, JSON state, and small scripts.
- Do not add credentials, API keys, or personal data to the repo.
- Do not claim a feature works unless it has been implemented and exercised.
- Keep this file current when the architecture changes.
