# CLAUDE.md — dotnet-learning-agent

This file is the architectural contract for this repository. Claude Code must follow it
when implementing or running any part of the workflow.

> **Status:** Phase 2A. Implemented: `/prepare-interview` (requirements gathering and
> confirmation only), the `requirements-formalizer` subagent, and `scripts/state.ps1`
> (state init/update, which requires PowerShell 7+). Everything after requirements
> formalization (research, planning, validation agents, approval, HTML), along with skills,
> hooks, and MCP configuration, is **not implemented yet**. Do not describe it as working
> until it exists and has been exercised.

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
  research/<topic>.md        # owner: the research subagent for <topic>
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
confirmed-input.md → requirements.md → research/<topic>.md → plan.md → validation/plan.json → approval.json → guide.html
```

- **Changing an upstream artifact invalidates every artifact downstream of it.** If
  `requirements.md` changes, all research, the plan, the validations, the approval, and the
  guide are stale. If one `research/<topic>.md` changes, the plan and everything after it are
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
- MCP servers are configured in a project-level config in a later phase. Credentials are
  **never** committed. They come from the environment or from local, git-ignored files.
- If an external tool is unavailable, the subagent must say so in its artifact rather than
  fabricate sources.

---

## 10. Repository layout

```
.claude/agents/     subagent definitions              (requirements-formalizer)
.claude/commands/   /prepare-interview command        (Phase 2A scope)
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
