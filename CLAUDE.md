# CLAUDE.md — dotnet-learning-agent

This file is the architectural contract for this repository. Claude Code must follow it
when implementing or running any part of the workflow.

> **Status:** Phase 3B. Implemented in `/prepare-interview`:
>
> - requirements gathering,
> - dynamic selection and parallel execution of research agents,
> - a global research coverage gate,
> - study-plan synthesis,
> - a plan-validation gate,
> - targeted retries routed to the owning agent,
> - downstream invalidation of dependent steps,
> - user-requested revisions of a validated plan (§6.2),
> - integrity checks on passed artifacts (§6.4).
>
> The subagents are `requirements-formalizer`, `dotnet-researcher`, `data-researcher`,
> `architecture-researcher`, `quality-validator`, and `study-planner`.
> `scripts/state.ps1` manages state with locking (PowerShell 7+) and is covered by
> `tests/run-tests.ps1`. The Microsoft Learn MCP server is configured in `.mcp.json`
> (§9.1). On 2026-10-12, one real run exercised the whole Phase 3A path end to end, from
> requirements through plan validation. Every step passed on attempt 1. The retry and
> invalidation paths are covered only by fixture tests, because the real run had no gate
> failure. On the same day, a real run exercised the Phase 3B revision path with live
> agents. A validated plan was revised from version 1 to version 2: `study-planner` and
> `quality-validator` were invoked again, research was not re-run, and the original version
> and revision history were preserved. The revised plan passed the plan gate and plan
> validation on attempt 1, kept the confirmed 150-minute budget, and left 3 non-blocking
> advisory findings. **Revision retries, failed revisions, and integrity violations
> (`resolve`) are still tested only with fixture artifacts.**
> Not implemented yet: human approval, HTML, resume (§7), hooks, and revisions of anything
> other than the plan. Known gaps are listed in §6.3.
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
`state.json` (`research.selected_agents`, with skipped agents in `research.not_selected`). That way the choice is auditable and survives a resume.

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

### 3.2 Mandatory topics and the coverage map

- **Mandatory topics** are the knowledge gaps the user stated plus any topics they
  explicitly asked for, verbatim. `requirements-formalizer` writes them to the
  `mandatory_topics` front matter of `requirements.md`. Derived topics, strengths, and
  validator suggestions are **optional**. An optional topic can only produce an advisory
  finding and never fails a gate.
- `requirements.md` also records `time_budget_hours`. It is a number only when the user's
  own numbers determine it; otherwise it is `unspecified`, and the plan must state its
  assumed budget.
- `research-selection.json` contains a `coverage` map: each mandatory topic → the assigned
  research topic(s) that cover it. `state.ps1 select` rejects a selection that leaves any
  mandatory topic unmapped. If no research agent can cover a mandatory topic, the
  coordinator stops and tells the user. Mandatory topics are never planned without
  research.

### 3.3 Synthesis and validation agents (implemented)

| Agent | Responsibility | Artifacts | Tools |
|---|---|---|---|
| `quality-validator` | Coverage mode: do the research artifacts together cover every mandatory topic? It also finds conflicts, unsupported claims, and misplaced responsibility. Plan mode: does the plan meet the requirements? It names the owner of every finding and never edits what it validates. | `validation/coverage.{json,md}`, `validation/plan.{json,md}` | `Read`, `Write`, `microsoft_docs_fetch` (at most 5 claim checks per report) |
| `study-planner` | Synthesizes `plan.md` from requirements and validated research. It prioritizes the confirmed gaps, stays within the budget, and cites only URLs that appear in research. It does not research. | `plan.md` | `Read`, `Write` |

---

## 4. Execution rules: sequential vs. parallel

**Sequential** (each step depends on the one before):

1. Requirements gathering → `requirements.md`
2. Agent selection (coordinator) → `research-selection.json`, with the coverage map
3. Research (see below) → `research/<area>.md`
4. Global coverage gate (`coverage` step, quality-validator) → `validation/coverage.json`
5. Learning-plan synthesis (`plan` step, study-planner, needs all research) → `plan.md`
6. Plan validation (`plan-validation` step, quality-validator) → `validation/plan.json`
7. Human approval (not implemented yet)
8. HTML generation (not implemented yet)

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
  validation/coverage.json   # owner: quality-validator (coverage report; .md summary beside it)
  plan.md                    # owner: study-planner
  validation/plan.json       # owner: quality-validator (plan report; .md summary beside it)
  validation/history/        # owner: coordinator (state.ps1 archives every report attempt here)
  versions/                  # owner: coordinator (state.ps1 snapshots every accepted artifact version)
  revision-request.json      # owner: coordinator (the latest user-confirmed revision request)
  revisions/                 # owner: coordinator (state.ps1 archives each revision request)
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
confirmed-input.md → requirements.md → research/<area>.md → validation/coverage.json → plan.md → validation/plan.json → approval.json → guide.html
```

**Implemented (Phase 3A):** `state.ps1` records the input hashes of every downstream step
(`coverage`, `plan`, `plan-validation`) at `start`. On every state save, and before every
`start`, it resets a downstream step to `pending`, with a fresh 3-attempt budget and an
`invalidated` history entry, if either of these is true:

- one of its input steps is no longer `passed`,
- one of its input files changed.

A `complete` whose inputs changed during the attempt returns `stale`, which is not counted
as a failed attempt. Research steps are not invalidated automatically: `state.ps1` refuses
to start or complete research on a changed `requirements.md` or `confirmed-input.md`, but
re-running requirements is not supported yet.

Only a supported change invalidates downstream steps: an owner re-running its step (a
retry, a requested revision, or a `discard`). A passed artifact edited outside the workflow
is an integrity violation (§6.4). It blocks dependent steps and is never propagated.

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

### 6.1 Coverage and plan gates (implemented)

Each gate combines deterministic checks in `state.ps1` with the validator's semantic
review.

| Gate | Deterministic (`state.ps1 complete`) | Semantic (`quality-validator`) |
|---|---|---|
| `coverage` | The report parses and has the schema below. Every mandatory topic is assessed exactly once. Each mapped `### <research topic>` exists. The verdict matches the blocking findings. | Depth per mandatory topic, conflicting findings, unsupported claims, misplaced responsibility |
| `plan` | Required sections. One `### <mandatory topic>` with a source per topic. The schedule's minutes total at most `budget_hours`, which equals the confirmed budget when there is one. `planned_hours` matches the schedule. Theory, practice, and interview sessions per mandatory topic, plus a revision session. `research_inputs` exist and match the selection. **Every URL appears in a research artifact.** | (done by `plan-validation`) |
| `plan-validation` | Report schema and verdict, as for coverage | Personalization, session limits, repeated assumptions, grounding against research |

**Report schema:**

- `report`, `run_id`, `generated_by: quality-validator`, and `verdict` (`pass`/`fail`),
- `mandatory_topics[]` with `topic` and `status` (`covered`/`partial`/`missing`),
- `findings[]` with `severity` (`blocking`/`advisory`), `category`, `owner`, `topic`,
  `message`, and `fix`,
- `optional_recommendations[]`.

A topic that is not `covered` must have a blocking finding. An `optional_topic` finding can
never be blocking. A Markdown summary must exist beside the JSON.

**Routing (targeted retry):** a failed report gate sends each blocking finding to the step
that owns it.

| Finding owner | Result |
|---|---|
| A research agent | Its `research-<area>` step is marked `failed` by that gate, which counts against its 3 attempts. Only that agent is re-run, with the findings as `GATE_FEEDBACK`. |
| `study-planner` | The `plan` step is marked failed. Only the planner is re-run. |
| `quality-validator`, or a malformed report | Only the validator is re-run, using that gate step's own attempts. |
| `coordinator` or `requirements-formalizer` | Non-retryable. The gate is marked blocked, nobody is re-run, and the run fails and is reported. |

Downstream steps are then invalidated (§5.2). Passed research for other areas is never
touched. Every report attempt is archived in `validation/history/`.

### 6.2 Gate-failure retries vs. requested revisions (implemented, Phase 3B)

These are two different mechanisms, and they stay separate.

| | Gate-failure retry | Requested revision |
|---|---|---|
| Trigger | A deterministic gate fails, or a validator report has a **blocking** finding | The **user** explicitly asks for a change to a validated plan, possibly by picking an advisory finding |
| Step state | Step is `running` or `failed` | Step has `passed`, and every step after it has passed (the run is paused at approval) |
| Who decides | `state.ps1` routes the finding to its owner automatically | Only the user. The coordinator records the request; agents and advisory findings never open one |
| Limit | **3 attempts per artifact version** (`$MaxAttempts`) | **3 revisions per artifact per run** (`$MaxRevisions`). Each revised version also gets its own 3 attempts |
| Recorded in | `steps.<s>.history` (each entry tagged with `version`, and `revision` when it belongs to one) | `state.revisions[]`, plus `revisions/<id>-request.json` (the archived request) |
| Downstream | Dependent steps are invalidated (§5.2) | The same: dependent steps are invalidated and validated again |

**Revisable artifacts:** only `plan` (owner `study-planner`). Research and requirements
cannot be revised, because re-running requirements is not supported.

**Revision lifecycle** (`state.ps1 revise -RunId <id> -Step plan -RequestFile <json>`):

1. **Request.** The coordinator writes `revision-request.json` with `step`,
   `requested_by: user`, `source` (`user` or `advisory`, with `advisory_findings` IDs that
   must exist as advisory findings in the current `validation/plan.json`), `reason`,
   `feedback`, and `user_confirmation` (the user's confirming reply, verbatim). A request
   missing any of these, or naming another actor, is rejected and nothing is recorded.
2. **Open.** `revise` checks integrity (§6.4), that the plan and plan validation have
   passed, that no revision is open, and the revision limit. It then archives the request,
   records `rev-NNN` in `state.revisions` (`status: open`, base version, base hash, base
   snapshot, base attempt), and only then reopens the plan: `status: pending`,
   `attempts: 0`, `active_revision: rev-NNN`. The plan's `history` is not touched.
   `plan-validation` is invalidated. Research and coverage are not touched.
3. **Regenerate.** The planner gets the original plan (its snapshot), the confirmed
   feedback, and the validated research. The plan gate and its retries work as usual, on
   the new version's own 3 attempts.
4. **Validate.** Plan validation runs again, with the feedback. A blocking finding is
   routed as usual. If it reopens research, the revision stays open until the whole chain
   has passed again.
5. **Close.** When the plan and everything after it have passed, the revision becomes
   `completed`, with `result_version` and `result_sha256`. If a step in its chain runs out
   of attempts, the revision becomes `failed` and the run fails. There is no automatic
   rollback; the last accepted version stays in `versions/`.

**Accepted versions:** each time a step passes, `state.ps1` records `version`, `sha256`,
`attempt`, `agent_id`, and `revision` in `steps.<s>.accepted_versions`, and copies the
artifact to `versions/<step>-v<N>.<ext>`. A plan that passes its gate but is then rejected
by plan validation still counts as an accepted version of the plan step.

Advisory findings are never routed. The passing `complete` of a report step prints them as
`suggested_revisions`, which the coordinator may offer to the user. The coordinator must
**not** edit an artifact itself to apply any fix (§5).

### 6.3 Known limitations (Phase 3B)

- **Partly exercised in a real run.** One live revision (v1 → v2) passed on its first
  attempt, and `verify` found no violations. Revision retries, a revision that runs out of
  attempts, and integrity violations with `resolve` are tested with fixtures only.
- **Authorization is recorded, not proven.** `state.ps1` can require an explicit,
  well-formed request that quotes the user's confirmation, but it cannot verify that the
  user actually typed it. The coordinator prompt is the only enforcement.
- **Only the plan can be revised**, one revision at a time, and only after plan
  validation passed. Feedback that changes confirmed requirements or needs new research is
  out of scope for a revision.
- **No rollback.** A revision that exhausts its attempts fails the run. The previous
  accepted plan is kept in `versions/`, but no action restores it as the current plan.
- **Integrity covers step artifacts only.** It checks each passed step's main artifact
  (`requirements.md`, `research/*.md`, `validation/*.json`, `plan.md`). The validator's
  Markdown summaries, `confirmed-input.md`, and `research-selection.json` are not covered.
  `confirmed-input.md` changes are still caught as stale inputs.
- **Runs created before Phase 3B** have no version snapshots for steps that passed then.
  `restore` is unavailable for them (revert by hand or `discard`). A revision of such a plan
  records the current, hash-verified plan as version 1 first.

### 6.4 Passed-artifact integrity (implemented, Phase 3B)

Only an artifact's owner may change it, and only while its step is not `passed`. On every
save, `state.ps1` compares each passed step's artifact with its recorded `artifact_sha256`.

- A mismatch is an **integrity violation**. `state.json` records it under `integrity`, and
  the run's `workflow_status` becomes `blocked`.
- The modified content is **never** accepted, and never treated as a legitimate input
  change: nothing downstream is invalidated by it.
- `start` and `complete` are refused for every step that depends on the modified artifact.
  A refused `complete` is not a failed attempt; the step stays `running`. `select` and
  `revise` are refused while any violation exists.
- `state.ps1 verify` reports violations. They are resolved only by an explicit action:
  - reverting the file to its accepted content, by hand or with
    `state.ps1 resolve -Step <s> -Resolution restore` (copies back the snapshot of the
    accepted version), or
  - `state.ps1 resolve -Step <s> -Resolution discard`: the step returns to `pending` with
    a fresh budget (like an invalidation), its owner regenerates it, and dependent steps
    are invalidated. Not available for `requirements`.

  Both resolutions first copy the modified file to `versions/<step>-modified-<time>` for
  audit, and record an event in `integrity.events`.

URLs are extracted with apostrophes kept inside them (a Learn anchor such as
`...-microservice's-autonomy` stays whole). A trailing apostrophe, like other trailing
punctuation, is trimmed.

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
  tracked separately (§6.2). The revision mechanism exists (Phase 3B); the approval prompt
  that would trigger it does not yet.
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
.claude/agents/     subagent definitions              (requirements, 3 research, validator, planner)
.claude/commands/   /prepare-interview command        (Phase 3B scope)
.claude/skills/     reusable skills                   (planned)
.claude/hooks/      guardrail hooks                   (planned)
scripts/            deterministic helpers             (state.ps1)
tests/              state.ps1 test suite              (run-tests.ps1)
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
