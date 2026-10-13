#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic workflow-state helper for dotnet-learning-agent runs.

.DESCRIPTION
    The coordinator (/prepare-interview) is the only caller. Subagents never run this.
    Every read-modify-write of state.json holds a per-run lock (state.lock), so parallel
    calls are safe, and every write is atomic (temp file in the same directory, then rename).

    Steps, in dependency order:
      requirements → research-<area> (parallel) → coverage → plan → plan-validation
        → approval (the user's decision) → render (final HTML; the renderer is not built yet)

    Actions:
      init      Create a new run directory and state.json. Prints run paths as JSON.
      select    Record the research-agent selection (with the mandatory-topic coverage map)
                from -SelectionFile; create the research steps and the downstream steps.
      start     Mark a step as running and increment its attempt count (max 3).
      complete  Verify the step's artifact, then mark the step passed or failed. For the
                coverage and plan-validation gates, blocking findings are routed to the
                step that owns them (targeted retry).
      fail      Mark the current attempt of a step as failed with a reason.
                -NoRetry marks the failure as not worth retrying (e.g. tools unavailable).
      revise    Reopen a passed, validated artifact (only `plan`) for a user-requested
                revision described in -RequestFile. Records the request first; the revised
                version gets its own attempt budget (CLAUDE.md §6.2).
      decide    Apply the oldest unconsumed user decision (approve, reject, request_changes)
                from the decision ledger runs/<id>/approval/decisions.jsonl. Only valid,
                unconsumed evidence bound to the current validated plan's SHA-256 is applied;
                approval.json and state.json are never evidence (CLAUDE.md §8). This script
                has no command that writes ledger entries.
      quarantine-ledger
                Move a structurally invalid, unconsumed ledger suffix (from the first malformed
                line to the end) to approval/quarantine/q-NNN.jsonl and record it. Refuses a
                valid ledger, never touches consumed entries, and never creates a decision.
                An interrupted run is resumed by running it again.
      ledger-status
                Read-only, takes no lock, writes nothing: whether a decision on the current
                plan can be recorded now, and where the ledger's chain ends. Used by the
                UserPromptSubmit hook, which holds the state lock while it appends.
      verify    Check that every passed artifact still has its recorded hash.
      resolve   Resolve an integrity violation of one step: -Resolution restore (copy back the
                accepted version) or discard (re-run the owner on a fresh budget).
      show      Print state.json.

    On every save, passed artifacts are checked against their recorded hashes (a mismatch
    blocks the run), and downstream steps whose input steps are no longer passed, or whose
    input files changed, are reset to pending with a fresh attempt budget (CLAUDE.md §5.2).

.EXAMPLE
    pwsh -NoProfile -File scripts/state.ps1 init -Label senior-backend
    pwsh -NoProfile -File scripts/state.ps1 start -RunId <id> -Step requirements
    pwsh -NoProfile -File scripts/state.ps1 complete -RunId <id> -Step requirements -AgentId <agent-id>
    pwsh -NoProfile -File scripts/state.ps1 select -RunId <id> -SelectionFile runs/<id>/research-selection.json
    pwsh -NoProfile -File scripts/state.ps1 start -RunId <id> -Step research-data
    pwsh -NoProfile -File scripts/state.ps1 complete -RunId <id> -Step coverage -AgentId <agent-id>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('init', 'select', 'start', 'complete', 'fail', 'revise', 'decide', 'quarantine-ledger', 'ledger-status', 'verify', 'resolve', 'show')]
    [string]$Action,

    [string]$RunId,
    [string]$Step,
    [string]$Label = 'run',
    [string]$AgentId,
    [string]$Reason,
    [string]$SelectionFile,
    [string]$RequestFile,
    [ValidateSet('restore', 'discard')]
    [string]$Resolution,
    [switch]$NoRetry,
    # Overridable for testing; defaults to <repo>/runs.
    [string]$RunsRoot = (Join-Path $PSScriptRoot '..' 'runs')
)

$ErrorActionPreference = 'Stop'
# Gate-failure retries: attempts per artifact version (the initial attempt plus 2 retries).
$MaxAttempts = 3
# User-requested revisions: revisions per artifact per run. Separate from $MaxAttempts.
$MaxRevisions = 3
# Steps whose passed artifact may be reopened by a requested revision.
$RevisableSteps = @('plan')
$MinResearchSources = 3

# Research agent registry: area -> owning agent. Step name is "research-<area>",
# artifact is "runs/<run-id>/research/<area>.md".
$ResearchAreas = [ordered]@{
    dotnet       = @{ agent = 'dotnet-researcher';       require_ms_learn = $true }
    data         = @{ agent = 'data-researcher';         require_ms_learn = $true }
    architecture = @{ agent = 'architecture-researcher'; require_ms_learn = $false }
}

# Steps after research, in dependency order. `report` steps are written by the
# quality-validator (JSON report + Markdown summary); `plan` is written by the study-planner.
$DownstreamSteps = [ordered]@{
    'coverage'        = @{ agent = 'quality-validator'; artifact = 'validation/coverage.json'; summary = 'validation/coverage.md'; kind = 'report'; report = 'coverage' }
    'plan'            = @{ agent = 'study-planner';     artifact = 'plan.md';                  kind = 'plan' }
    'plan-validation' = @{ agent = 'quality-validator'; artifact = 'validation/plan.json';     summary = 'validation/plan.md';     kind = 'report'; report = 'plan' }
}

# Owners that can never be retried by re-running a subagent: the coordinator's own
# selection and the requirements are fixed for the run.
$NonRetryableOwners = @('coordinator', 'requirements-formalizer')

$FindingCategories = @('missing_coverage', 'conflicting_findings', 'unsupported_claim', 'misplaced_responsibility',
    'requirements_mismatch', 'time_budget', 'traceability', 'structure', 'optional_topic', 'other')

$PlanActivities = @('theory', 'practice', 'interview', 'revision', 'mock')

# Human approval (CLAUDE.md §8). Decisions are evidence lines in an append-only, hash-chained
# ledger. Only the UserPromptSubmit hook (Phase 4B) writes it; this script only reads it.
$LedgerPath = 'approval/decisions.jsonl'
$LedgerSource = 'user-prompt-submit'
$LedgerDecisions = @('approve', 'reject', 'request_changes')
$ZeroSha256 = '0' * 64
# Which transcript promptSource values count as a user's own prompt (CLAUDE.md §8.2). Pinned
# with the hooks; defaults to interactive typing only.
$ApprovalPolicyPath = Join-Path $PSScriptRoot '..' '.claude' 'hooks' 'approval-policy.json'

# Section headings each artifact type must contain (structure gate).
$RequirementsHeadings = @(
    '# Interview Preparation Requirements'
    '## Summary'
    '## Target Role and Seniority'
    '## Topics'
    '## Knowledge Gaps'
    '## Time Availability'
    '## Learning Preferences'
    '## Constraints'
    '## Acceptance Criteria'
    '## Open Questions and Assumptions'
)
$ResearchHeadings = @(
    '## Scope'
    '## Findings'
    '## Interview Questions'
    '## Hands-on Exercises'
    '## Sources'
    '## Gaps and Limitations'
)
$PlanHeadings = @(
    '## Summary'
    '## Assumptions'
    '## Time Budget'
    '## Schedule'
    '## Topic Plans'
    '## Revision and Mock Interviews'
    '## Sources'
)

function Get-Now { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Get-FileHash256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# Like Get-FileHash256, but $null for a missing file, so a deleted input reads as changed.
function Get-InputHash([string]$Path) { if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-FileHash256 $Path } else { $null } }

function Get-StringHash256([string]$Text) {
    $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($Text))
    try { (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant() } finally { $stream.Dispose() }
}

function Write-JsonAtomic([string]$Path, $Object) { Write-TextAtomic $Path (($Object | ConvertTo-Json -Depth 10) + "`n") }

# UTF-8 without BOM, written to a temp file in the same directory, then renamed over $Path.
function Write-TextAtomic([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, [System.Text.UTF8Encoding]::new($false))
        # On Windows, replacing a file fails while another process (a reader outside the lock,
        # an editor, an antivirus scan) has it open. Retry briefly instead of failing the step.
        $deadline = (Get-Date).AddSeconds(5)
        while ($true) {
            try { [System.IO.File]::Move($tmp, $Path, $true); break }
            catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                if ((Get-Date) -gt $deadline) { throw }
                Start-Sleep -Milliseconds 10
            }
        }
    }
    finally {
        # Only left behind if the write or rename failed; never leave orphaned temp files.
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-RunDir {
    if (-not $RunId) { throw 'Missing -RunId.' }
    if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid run id '$RunId'." }
    $dir = Join-Path $RunsRoot $RunId
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'state.json'))) { throw "No state.json for run '$RunId' under '$RunsRoot'." }
    return $dir
}

# Exclusive per-run lock (FileShare.None). Released by the `finally` at the end of the script;
# if the process dies first, the OS closes the handle and DeleteOnClose removes the file.
function Enter-StateLock([string]$RunDir) {
    $path = Join-Path $RunDir 'state.lock'
    $deadline = (Get-Date).AddSeconds(15)
    while ($true) {
        try {
            return [System.IO.FileStream]::new($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ((Get-Date) -gt $deadline) { throw "Timed out waiting for state lock: $path" }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Read-State([string]$RunDir) {
    $params = @{ AsHashtable = $true }
    # Keep ISO timestamps as strings instead of converting them to DateTime (PowerShell 7.5+).
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $params.DateKind = 'String' }
    $state = Get-Content -LiteralPath (Join-Path $RunDir 'state.json') -Raw | ConvertFrom-Json @params
    # Runs created before approval existed get the approval and render steps on first read.
    Initialize-ApprovalSteps $state
    return $state
}

function Save-State([string]$RunDir, $State) {
    $violations = Update-Integrity $RunDir $State
    Update-Invalidation $RunDir $State $violations
    Update-Revisions $State
    Update-Approval $RunDir $State $violations
    Update-Workflow $State
    $State.updated_at = Get-Now
    Write-JsonAtomic (Join-Path $RunDir 'state.json') $State
}

function Get-StepEntry($State) {
    if (-not $Step) { throw 'Missing -Step.' }
    if (-not $State.steps.Contains($Step)) { throw "Unknown step '$Step'." }
    return $State.steps[$Step]
}

function Get-ArtifactPath([string]$RunDir, $Entry) {
    Join-Path $RunDir $Entry.artifact.Substring("runs/$RunId/".Length)
}

function Get-ResearchStepNames($State) { @($State.steps.Keys | Where-Object { $_ -like 'research-*' }) }

function Test-Exhausted($Entry) {
    $Entry.status -eq 'failed' -and ($Entry.attempts -ge $MaxAttempts -or $Entry['retry_blocked'])
}

function Get-AttemptsLeft($Entry) { if ($Entry['retry_blocked']) { 0 } else { $MaxAttempts - $Entry.attempts } }

# The items of a JSON array that may be absent (older runs) or null. Always wrap the call
# in @(...) to get an array.
function Get-List($Value) { if ($null -ne $Value) { $Value } }

# Version number the step's next accepted artifact will get.
function Get-NextVersion($Entry) { @(Get-List $Entry['accepted_versions']).Count + 1 }

# Run-relative path ("plan.md") of a step's artifact.
function Get-RelativeArtifact($Entry) { $Entry.artifact.Substring("runs/$RunId/".Length) }

# Steps whose artifact the given step is built from, directly or transitively.
function Get-UpstreamSteps($State, [string]$Name) {
    $research = @(Get-ResearchStepNames $State)
    switch -Wildcard ($Name) {
        'requirements' { @() }
        'research-*' { @('requirements') }
        'coverage' { @('requirements') + $research }
        'plan' { @('requirements') + $research + @('coverage') }
        'plan-validation' { @('requirements') + $research + @('coverage', 'plan') }
        'approval' { @('requirements') + $research + @('coverage', 'plan', 'plan-validation') }
        'render' { @('requirements') + $research + @('coverage', 'plan', 'plan-validation', 'approval', 'approval-ledger', 'render-output') }
        default { @() }
    }
}

# ---------------------------------------------------------------- Markdown parsing helpers

function Get-Lines([string]$Path) { @(Get-Content -LiteralPath $Path -Encoding utf8 | ForEach-Object { $_.TrimEnd() }) }

# Minimal YAML front matter: `key: value` scalars and `key:` followed by `  - item` lists.
function Get-FrontMatter([string[]]$Lines) {
    $fm = [ordered]@{}
    if ($Lines.Count -eq 0 -or $Lines[0] -ne '---') { return $fm }
    $key = $null
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -eq '---') { break }
        if ($key -and $line -match '^\s+-\s*(.*)$') {
            if ($fm[$key] -isnot [System.Collections.Generic.List[string]]) { $fm[$key] = [System.Collections.Generic.List[string]]::new() }
            $fm[$key].Add((Get-Unquoted $Matches[1]))
            continue
        }
        if ($line -match '^([A-Za-z0-9_]+):\s*(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            $fm[$key] = if ($value -eq '') { [System.Collections.Generic.List[string]]::new() } else { Get-Unquoted $value }
        }
    }
    return $fm
}

function Get-Unquoted([string]$Value) {
    $v = $Value.Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) { return $v.Substring(1, $v.Length - 2) }
    return $v
}

# Lines strictly between $Heading and the next heading of the same or higher level.
function Get-SectionLines([string[]]$Lines, [string]$Heading) {
    $level = ($Heading -replace '^(#+).*', '$1').Length
    $stop = '^#{1,' + $level + '} '
    $inSection = $false
    foreach ($line in $Lines) {
        if ($line -eq $Heading) { $inSection = $true; continue }
        if ($inSection -and $line -match $stop) { break }
        if ($inSection) { $line }
    }
}

function Get-Urls([string[]]$Lines) {
    # An apostrophe is valid inside a URL (e.g. a Learn anchor "...-microservice's-autonomy"),
    # so it is only trimmed when it ends the match, like other trailing punctuation.
    $urls = foreach ($line in $Lines) {
        foreach ($m in [regex]::Matches($line, 'https?://[^\s<>()\[\]"`|]+')) { $m.Value.TrimEnd('.', ',', ';', ':', "'") }
    }
    @($urls | Select-Object -Unique)
}

# Distinct URLs in the lines between $Heading and the next "## " heading.
function Get-SectionUrls([string[]]$Lines, [string]$Heading) { Get-Urls @(Get-SectionLines $Lines $Heading) }

function Get-NormalizedUrl([string]$Url) { $Url.TrimEnd('/') }

function Test-Number([string]$Value) { $Value -match '^\d+(\.\d+)?$' -and [double]$Value -gt 0 }

# ---------------------------------------------------------------- downstream inputs and invalidation

# Steps that must be `passed` before a downstream step can start.
function Get-Prerequisites($State, [string]$Name) {
    switch ($Name) {
        'coverage' { Get-ResearchStepNames $State }
        'plan' { @('coverage') }
        'plan-validation' { @('plan') }
    }
}

# Relative path -> current SHA-256 of every file a downstream step is built from.
function Get-DownstreamInputs([string]$RunDir, $State, [string]$Name) {
    $files = [ordered]@{ 'requirements.md' = Get-InputHash (Join-Path $RunDir 'requirements.md') }
    foreach ($s in Get-ResearchStepNames $State) {
        $rel = "research/$($State.steps[$s].area).md"
        $files[$rel] = Get-InputHash (Join-Path $RunDir $rel)
    }
    if ($Name -in 'plan', 'plan-validation') { $files['validation/coverage.json'] = Get-InputHash (Join-Path $RunDir 'validation/coverage.json') }
    if ($Name -eq 'plan-validation') { $files['plan.md'] = Get-InputHash (Join-Path $RunDir 'plan.md') }
    return $files
}

# Reasons a downstream step's inputs are no longer valid (empty = fresh). Files in
# $IgnoreFiles (passed artifacts that were modified by hand) are not legitimate input
# changes: they are integrity violations and must be resolved first, not propagated.
function Get-StaleReasons([string]$RunDir, $State, [string]$Name, [string[]]$IgnoreFiles = @()) {
    $entry = $State.steps[$Name]
    $reasons = @(foreach ($p in Get-Prerequisites $State $Name) {
            if ($State.steps[$p].status -ne 'passed') { "input step '$p' is $($State.steps[$p].status)" }
        })
    if ($entry.inputs_sha256) {
        $current = Get-DownstreamInputs $RunDir $State $Name
        foreach ($k in $current.Keys) {
            if ($k -in $IgnoreFiles) { continue }
            if ($current[$k] -ne $entry.inputs_sha256[$k]) { $reasons += "$k changed" }
        }
    }
    return , $reasons
}

# Invalidation is not a failed attempt: the step gets a fresh budget for its new inputs.
function Reset-Invalidated($Entry, [string[]]$Reasons) {
    $Entry.status = 'pending'
    $Entry.attempts = 0
    $Entry.retry_blocked = $false
    $Entry.inputs_sha256 = $null
    $Entry.artifact_sha256 = $null
    $Entry.completed_at = Get-Now
    $Entry.history += @([ordered]@{ result = 'invalidated'; reasons = $Reasons; at = (Get-Now) })
}

function Update-Invalidation([string]$RunDir, $State, $Violations = @()) {
    if (-not $State.steps.Contains('coverage')) { return }
    $ignore = @($Violations | ForEach-Object { $_.artifact.Substring("runs/$RunId/".Length) })
    foreach ($name in $DownstreamSteps.Keys) {
        $entry = $State.steps[$name]
        if ($entry.status -notin 'passed', 'failed' -or -not $entry.inputs_sha256) { continue }
        $reasons = Get-StaleReasons $RunDir $State $name $ignore
        if ($reasons.Count -gt 0) { Reset-Invalidated $entry $reasons }
    }
}

# ---------------------------------------------------------------- artifact integrity

# Passed steps whose artifact no longer has the hash recorded when it passed. Only the
# artifact's owner may change it, and only while its step is not passed, so any mismatch
# is a manual (or otherwise unsupported) modification.
function Get-IntegrityViolations([string]$RunDir, $State) {
    $found = foreach ($name in @($State.steps.Keys)) {
        $e = $State.steps[$name]
        # A recorded decision (approval.json) is held to its hash just like a passed artifact.
        if ($e.status -notin 'passed', 'approved', 'rejected' -or -not $e.artifact_sha256) { continue }
        $actual = Get-InputHash (Get-ArtifactPath $RunDir $e)
        if ($actual -ne $e.artifact_sha256) {
            [ordered]@{ step = $name; artifact = $e.artifact; expected_sha256 = $e.artifact_sha256; actual_sha256 = $actual }
        }
    }
    # Consumed ledger entries are history: they may never change, disappear, or be reordered.
    $a = $State.steps['approval']
    if ($a -and [int]$a.consumed_through -gt 0) {
        $ledger = Read-Ledger $RunDir
        $actual = if ($ledger.lines.Count -ge [int]$a.consumed_through) { Get-LedgerPrefixSha $ledger ([int]$a.consumed_through) } else { $null }
        if ($actual -ne $a.consumed_sha256) {
            $found = @($found) + @([ordered]@{ step = 'approval-ledger'; artifact = "runs/$RunId/$LedgerPath"; expected_sha256 = $a.consumed_sha256; actual_sha256 = $actual })
        }
    }
    # Unauthorized output: a guide.html that no render attempt of this run produced. (While
    # render runs, the renderer is writing it; a passed render is checked above.)
    $r = $State.steps['render']
    $guide = Join-Path $RunDir 'guide.html'
    if ($r -and $r.status -notin 'running', 'passed' -and (Test-Path -LiteralPath $guide -PathType Leaf)) {
        $actual = Get-FileHash256 $guide
        $known = @(@(Get-List $r['accepted_versions']) | ForEach-Object { $_.sha256 }) + @(@(Get-List $r['history']) | ForEach-Object { $_['output_sha256'] })
        if ($actual -notin $known) {
            $found = @($found) + @([ordered]@{ step = 'render-output'; artifact = "runs/$RunId/guide.html"; expected_sha256 = $null; actual_sha256 = $actual })
        }
    }
    , @($found)
}

# Records the current integrity status on the state and returns the violations.
function Update-Integrity([string]$RunDir, $State) {
    if (-not $State['integrity']) { $State.integrity = [ordered]@{ status = 'ok'; violations = @(); detected_at = $null; events = @() } }
    $violations = Get-IntegrityViolations $RunDir $State
    if ($violations.Count -gt 0) {
        if ($State.integrity.status -ne 'violated') { $State.integrity.detected_at = Get-Now }
        $State.integrity.status = 'violated'
        $State.integrity.violations = $violations
    }
    else {
        $State.integrity.status = 'ok'
        $State.integrity.violations = @()
        $State.integrity.detected_at = $null
    }
    return , $violations
}

function Format-Violation($V) {
    $rel = $V.artifact.Substring("runs/$RunId/".Length)
    $found = if ($V.actual_sha256) { $V.actual_sha256.Substring(0, 12) } else { 'missing' }
    if ($V.step -eq 'approval-ledger') {
        return "$rel changed after decisions in it were consumed (recorded $($V.expected_sha256.Substring(0, 12)), found $found). " +
        'Consumed entries can never change: put the consumed lines back exactly as they were, by hand.'
    }
    if ($V.step -eq 'render-output') {
        return "guide.html ($found) was not produced by a render of an approved plan. It is never accepted and nothing is deleted automatically: move or delete it yourself."
    }
    $fix = if ($V.step -eq 'requirements') { 'restore' } else { 'restore|discard' }
    "$rel changed after it passed (step '$($V.step)'; recorded $($V.expected_sha256.Substring(0, 12)), found $found). " +
    "Restore the file, or run: state.ps1 resolve -RunId $RunId -Step $($V.step) -Resolution $fix"
}

# Refuses an action that would build on a manually modified artifact. With -Step, only
# violations in that step's upstream chain block it; without, any violation blocks.
# The violation is saved first, so `state.json` shows the blocked run.
function Assert-Integrity([string]$RunDir, $State, [string]$ForStep) {
    $violations = Get-IntegrityViolations $RunDir $State
    if ($ForStep) {
        $upstream = @(Get-UpstreamSteps $State $ForStep)
        $relevant = @($violations | Where-Object { $_.step -in $upstream })
    }
    else { $relevant = $violations }
    if ($relevant.Count -eq 0) { return }
    Save-State $RunDir $State
    throw "Integrity violation: $(($relevant | ForEach-Object { Format-Violation $_ }) -join ' ')"
}

# ---------------------------------------------------------------- accepted versions and revisions

# Records the artifact a step just passed with as a new accepted version, and keeps a
# snapshot of it under versions/ (used to restore it, and as a revision's base).
function Add-AcceptedVersion([string]$RunDir, $Entry, [string]$Name) {
    $version = Get-NextVersion $Entry
    $src = Get-ArtifactPath $RunDir $Entry
    $snapshot = "versions/$Name-v$version$([System.IO.Path]::GetExtension($src))"
    New-Item -ItemType Directory -Path (Join-Path $RunDir 'versions') -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination (Join-Path $RunDir $snapshot) -Force
    $record = [ordered]@{
        version     = $version
        sha256      = $Entry.artifact_sha256
        attempt     = $Entry.attempts
        agent_id    = $Entry.agent_id
        revision    = $Entry['active_revision']
        snapshot    = "runs/$RunId/$snapshot"
        accepted_at = $Entry.completed_at
    }
    $Entry.accepted_versions = @(Get-List $Entry['accepted_versions']) + @($record)
    $Entry.version = $version
    return $record
}

# A run created before versions were recorded has a passed artifact but no version record.
# Record it as version 1 (its hash was verified by Assert-Integrity) before revising it.
function Initialize-LegacyVersion([string]$RunDir, $Entry, [string]$Name) {
    if (@(Get-List $Entry['accepted_versions']).Count -gt 0) { return }
    $record = Add-AcceptedVersion $RunDir $Entry $Name
    $record.recorded_late = $true
}

# Open revisions complete when the revised step and every step after it have passed again,
# and fail when any of those steps runs out of attempts.
function Update-Revisions($State) {
    if (-not $State['revisions']) { return }
    $order = @($DownstreamSteps.Keys)
    foreach ($rev in @($State.revisions)) {
        if ($rev.status -ne 'open') { continue }
        $chain = @($order | Select-Object -Skip ([array]::IndexOf($order, $rev.step)))
        $entry = $State.steps[$rev.step]
        $exhausted = @($chain + @(Get-UpstreamSteps $State $rev.step) | Where-Object { Test-Exhausted $State.steps[$_] })
        if ($exhausted.Count -gt 0) {
            $rev.status = 'failed'
            $rev.failed_at = Get-Now
            $rev.failure_reason = "Step(s) out of attempts: $($exhausted -join ', ')"
            $entry.active_revision = $null
            continue
        }
        if (@($chain | Where-Object { $State.steps[$_].status -ne 'passed' }).Count -eq 0) {
            $rev.status = 'completed'
            $rev.completed_at = Get-Now
            $rev.result_version = $entry.version
            $rev.result_sha256 = $entry.artifact_sha256
            $entry.active_revision = $null
        }
    }
}

# Problems with a revision request (empty = valid). The request must come from the user,
# quote the user's explicit confirmation, and say what to change.
function Test-RevisionRequest([string]$RunDir, $State, $Request) {
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Request -isnot [System.Collections.IDictionary]) { $errors.Add('The request must be a JSON object.'); return , $errors }
    if ("$($Request['step'])" -ne $Step) { $errors.Add("'step' must be '$Step' (got '$($Request['step'])').") }
    if ("$($Request['requested_by'])" -ne 'user') { $errors.Add("'requested_by' must be 'user'. Only the user can request a revision; agents and advisory findings cannot.") }
    if (-not "$($Request['user_confirmation'])".Trim()) { $errors.Add("'user_confirmation' must quote the user's explicit confirmation of this revision.") }
    if (-not "$($Request['reason'])".Trim()) { $errors.Add("'reason' must say why the artifact is being revised.") }
    if (-not "$($Request['feedback'])".Trim()) { $errors.Add("'feedback' must state the changes the user confirmed.") }
    $source = "$($Request['source'])"
    if ($source -notin 'user', 'advisory') { $errors.Add("'source' must be 'user' or 'advisory'.") }
    if ($source -eq 'advisory') {
        $ids = @(Get-List $Request['advisory_findings'] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($ids.Count -eq 0) { $errors.Add("An 'advisory' revision must list the confirmed finding IDs in 'advisory_findings'.") }
        $report = Join-Path $RunDir $DownstreamSteps['plan-validation'].artifact
        $known = @{}
        if (Test-Path -LiteralPath $report -PathType Leaf) {
            $json = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json -AsHashtable
            foreach ($f in @(Get-List $json['findings'])) { if ($f -and $f['severity'] -eq 'advisory') { $known["$($f['id'])"] = $true } }
        }
        foreach ($id in $ids) { if (-not $known.ContainsKey($id)) { $errors.Add("Advisory finding '$id' is not an advisory finding in the current plan validation report.") } }
    }
    return , $errors
}

# Reasons a revision of step $Name cannot be opened now (empty = it can), in the order
# `revise` reports them.
function Get-RevisionBlockers($State, [string]$Name) {
    $entry = $State.steps[$Name]
    $errors = [System.Collections.Generic.List[string]]::new()
    $open = @(Get-List $State['revisions'] | Where-Object { $_.status -eq 'open' })
    if ($open.Count -gt 0) { $errors.Add("Revision '$($open[0].id)' is still open. Finish it before requesting another.") }
    if ($entry.status -ne 'passed') { $errors.Add("Step '$Name' is $($entry.status); only a passed artifact can be revised.") }
    $running = @($State.steps.Keys | Where-Object { $State.steps[$_].status -eq 'running' })
    if ($running.Count -gt 0) { $errors.Add("Cannot revise while step(s) are running: $($running -join ', ').") }
    $order = @($DownstreamSteps.Keys)
    $after = @($order | Select-Object -Skip ([array]::IndexOf($order, $Name) + 1))
    $unvalidated = @($after | Where-Object { $State.steps[$_].status -ne 'passed' })
    if ($unvalidated.Count -gt 0) { $errors.Add("Step '$Name' can be revised only after it is validated; not passed yet: $($unvalidated -join ', ').") }
    $used = @(Get-List $State['revisions'] | Where-Object { $_.step -eq $Name }).Count
    if ($used -ge $MaxRevisions) { $errors.Add("Revision limit reached: step '$Name' has used all $MaxRevisions revisions for this run.") }
    if ($State.steps['approval'] -and $State.steps.approval.status -eq 'rejected') { $errors.Add('The plan was rejected; rejection is final for this run.') }
    return , $errors
}

# Records a validated revision request and reopens step $Name (CLAUDE.md §6.2). The request
# is archived first: copied byte for byte from $CopyFrom, or serialized when there is no file.
function Open-Revision([string]$RunDir, $State, [string]$Name, $Request, [string]$CopyFrom) {
    $entry = $State.steps[$Name]
    $order = @($DownstreamSteps.Keys)
    $after = @($order | Select-Object -Skip ([array]::IndexOf($order, $Name) + 1))
    $used = @(Get-List $State['revisions'] | Where-Object { $_.step -eq $Name }).Count

    # Record the request (and the version it revises) before reopening anything.
    Initialize-LegacyVersion $RunDir $entry $Name
    $base = @(Get-List $entry.accepted_versions)[-1]
    if (-not $State['revisions']) { $State.revisions = @() }
    $id = 'rev-{0:000}' -f (@(Get-List $State.revisions).Count + 1)
    New-Item -ItemType Directory -Path (Join-Path $RunDir 'revisions') -Force | Out-Null
    $archived = "revisions/$id-request.json"
    if ($CopyFrom) { Copy-Item -LiteralPath $CopyFrom -Destination (Join-Path $RunDir $archived) -Force }
    else { Write-JsonAtomic (Join-Path $RunDir $archived) $Request }
    $record = [ordered]@{
        id                = $id
        step              = $Name
        artifact          = $entry.artifact
        owner             = $entry.agent
        requested_by      = 'user'
        source            = "$($Request['source'])"
        advisory_findings = @(Get-List $Request['advisory_findings'])
        reason            = "$($Request['reason'])"
        feedback          = "$($Request['feedback'])"
        user_confirmation = "$($Request['user_confirmation'])"
        request_file      = "runs/$RunId/$archived"
        request_sha256    = Get-FileHash256 (Join-Path $RunDir $archived)
        requested_at      = Get-Now
        base_version      = $base.version
        base_sha256       = $base.sha256
        base_snapshot     = $base.snapshot
        base_attempt      = $base.attempt
        status            = 'open'
        result_version    = $null
        result_sha256     = $null
        completed_at      = $null
    }
    if ($Request['evidence']) { $record.evidence = $Request['evidence'] }
    $State.revisions = @(Get-List $State.revisions) + @($record)

    # Reopen only the owner's step. Its gate history stays as it is; the new version
    # gets its own attempt budget. Downstream steps are invalidated on save.
    $entry.status = 'pending'
    $entry.attempts = 0
    $entry.retry_blocked = $false
    $entry.artifact_sha256 = $null
    $entry.active_revision = $id
    $entry.revisions = @(Get-List $entry['revisions']) + @($id)
    $before = [ordered]@{}
    foreach ($n in $after) { $before[$n] = $State.steps[$n].status }
    return [ordered]@{ record = $record; base = $base; used = $used; after = $after; before = $before }
}

# ---------------------------------------------------------------- human approval (CLAUDE.md §8)

# The approval and render steps follow plan-validation. Runs selected before they existed get
# them on first read.
function Initialize-ApprovalSteps($State) {
    if (-not $State.steps.Contains('plan-validation') -or $State.steps.Contains('approval')) { return }
    $State.steps.approval = [ordered]@{
        status                 = 'pending'   # pending | awaiting_decision | approved | rejected
        agent                  = 'user'
        artifact               = "runs/$RunId/approval.json"
        ledger                 = "runs/$RunId/$LedgerPath"
        attempts               = 0
        artifact_sha256        = $null
        agent_id               = $null
        completed_at           = $null
        decision               = $null
        decision_id            = $null
        ledger_seq             = $null
        ledger_entry_sha256    = $null
        plan_sha256            = $null
        plan_version           = $null
        plan_validation_sha256 = $null
        consumed_through       = 0
        consumed_sha256        = $null
        decisions              = @()
        history                = @()
    }
    $State.steps.render = [ordered]@{
        status          = 'pending'
        agent           = 'renderer'
        artifact        = "runs/$RunId/guide.html"
        attempts        = 0
        max_attempts    = $MaxAttempts
        inputs_sha256   = $null
        artifact_sha256 = $null
        agent_id        = $null
        started_at      = $null
        completed_at    = $null
        history         = @()
    }
}

# The ledger as raw lines (exact text, line endings removed) and the SHA-256 of each line.
# The hash of a line is what the next entry's prev_sha256 and the state refer to.
function Read-Ledger([string]$RunDir) {
    $path = Join-Path $RunDir $LedgerPath
    $ledger = [ordered]@{ exists = $false; lines = @(); shas = @() }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $ledger }
    $ledger.exists = $true
    $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $text -split "`n") { $lines.Add($l.TrimEnd("`r")) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $ledger.lines = @($lines)
    $ledger.shas = @($lines | ForEach-Object { Get-StringHash256 $_ })
    return $ledger
}

# Hash of the first $Count ledger lines; recorded when entries are consumed.
function Get-LedgerPrefixSha($Ledger, [int]$Count) { Get-StringHash256 (@($Ledger.lines | Select-Object -First $Count) -join "`n") }

# Structural problems of one ledger line (empty = well formed). The format is fixed:
#   schema 1, seq (1-based, contiguous), decision_id "dec-<seq:000>", prev_sha256 (hash of the
#   previous line, 64 zeros for the first), run_id, decision (approve | reject | request_changes),
#   plan_sha256, plan_version, feedback (request_changes only), prompt_sha256, prompt_id,
#   session_id, transcript_path, recorded_at, source "user-prompt-submit".
function Get-LedgerLineProblems([string]$Line, [int]$Seq, [string]$PrevSha) {
    $p = [System.Collections.Generic.List[string]]::new()
    try { $e = $Line | ConvertFrom-Json -AsHashtable } catch { $e = $null }
    if ($e -isnot [System.Collections.IDictionary]) { $p.Add("line $Seq is not a JSON object."); return , $p }
    if ("$($e['schema'])" -ne '1') { $p.Add("line ${Seq}: 'schema' must be 1.") }
    if ("$($e['seq'])" -ne "$Seq") { $p.Add("line ${Seq}: 'seq' must be $Seq (entries are contiguous).") }
    if ("$($e['decision_id'])" -ne ('dec-{0:000}' -f $Seq)) { $p.Add("line ${Seq}: 'decision_id' must be $('dec-{0:000}' -f $Seq).") }
    if ("$($e['prev_sha256'])" -ne $PrevSha) { $p.Add("line ${Seq}: 'prev_sha256' does not match the previous line (the chain is broken).") }
    if ("$($e['run_id'])" -ne $RunId) { $p.Add("line ${Seq}: 'run_id' must be '$RunId'.") }
    if ("$($e['source'])" -ne $LedgerSource) { $p.Add("line ${Seq}: 'source' must be '$LedgerSource'.") }
    $decision = "$($e['decision'])"
    if ($decision -notin $LedgerDecisions) { $p.Add("line ${Seq}: 'decision' must be one of $($LedgerDecisions -join ', ').") }
    foreach ($k in 'plan_sha256', 'prompt_sha256') { if ("$($e[$k])" -cnotmatch '^[0-9a-f]{64}$') { $p.Add("line ${Seq}: '$k' must be 64 lowercase hex characters.") } }
    if ("$($e['plan_version'])" -notmatch '^[1-9]\d*$') { $p.Add("line ${Seq}: 'plan_version' must be a positive integer.") }
    foreach ($k in 'prompt_id', 'session_id', 'transcript_path', 'recorded_at') { if (-not "$($e[$k])".Trim()) { $p.Add("line ${Seq}: '$k' is required.") } }
    $feedback = "$($e['feedback'])".Trim()
    if ($decision -eq 'request_changes' -and -not $feedback) { $p.Add("line ${Seq}: a request_changes decision must carry the user's 'feedback'.") }
    if ($decision -in 'approve', 'reject' -and $feedback) { $p.Add("line ${Seq}: only a request_changes decision carries 'feedback'.") }
    return , $p
}

# Structural problems of the whole ledger, checking every line and the chain between them.
function Get-LedgerProblems($Ledger) {
    $all = [System.Collections.Generic.List[string]]::new()
    $prev = $ZeroSha256
    for ($i = 0; $i -lt $Ledger.lines.Count; $i++) {
        $lineProblems = Get-LedgerLineProblems $Ledger.lines[$i] ($i + 1) $prev
        foreach ($p in $lineProblems) { $all.Add($p) }
        $prev = $Ledger.shas[$i]
    }
    return , $all
}

# 1-based number of the first malformed ledger line (0 = none). The chain makes every line
# after it untrustworthy too.
function Get-FirstBadLedgerLine($Ledger) {
    $prev = $ZeroSha256
    for ($i = 0; $i -lt $Ledger.lines.Count; $i++) {
        $lineProblems = Get-LedgerLineProblems $Ledger.lines[$i] ($i + 1) $prev
        if ($lineProblems.Count -gt 0) { return $i + 1 }
        $prev = $Ledger.shas[$i]
    }
    return 0
}

# The exact file content for a list of ledger lines.
function Get-LedgerText([string[]]$Lines) { if ($Lines.Count) { ($Lines -join "`n") + "`n" } else { '' } }

# Why the plan cannot be decided on now (empty = it can): the plan and its validation must
# have passed, and no revision may be open.
function Get-ApprovalBlockers($State) {
    $b = @(foreach ($n in 'plan', 'plan-validation') { if ($State.steps[$n].status -ne 'passed') { "step '$n' is $($State.steps[$n].status)" } })
    $open = @(Get-List $State['revisions'] | Where-Object { $_.status -eq 'open' })
    if ($open.Count -gt 0) { $b += "revision '$($open[0].id)' is open" }
    return , $b
}

function Get-AcceptedPromptSources {
    try {
        $policy = Get-Content -LiteralPath $ApprovalPolicyPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        $sources = @($policy['accepted_prompt_sources'] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($sources.Count) { return , $sources }
    }
    catch { }
    return , @('typed')
}

# Where the captured prompt came from, according to the session transcript (empty = accepted).
# The UserPromptSubmit hook cannot check this itself: the transcript entry of a prompt is
# written only after the hook runs. This is a consistency check, not proof of a human: the
# transcript is a local file that anything running as the user can write.
function Get-PromptOriginProblems($Entry) {
    $path = "$($Entry['transcript_path'])"
    $id = "$($Entry['prompt_id'])"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return , @("Origin not verifiable: the session transcript '$path' does not exist.") }
    $found = $null
    foreach ($l in [System.IO.File]::ReadLines($path)) {
        if (-not $l.Contains($id)) { continue }
        try { $t = $l | ConvertFrom-Json -AsHashtable } catch { continue }
        if ($t['type'] -eq 'user' -and "$($t['promptId'])" -eq $id -and $t['message'] -and $t['message']['content'] -is [string]) { $found = $t; break }
    }
    if (-not $found) { return , @("Origin not verifiable: prompt '$id' is not in the session transcript.") }
    $p = @()
    $accepted = Get-AcceptedPromptSources
    if ("$($found['promptSource'])" -notin $accepted) { $p += "Not a user-typed prompt: the transcript records promptSource '$($found['promptSource'])' (accepted: $($accepted -join ', '))." }
    if ($found['origin']) { $p += "System-generated prompt: the transcript records origin '$($found['origin']['kind'])'." }
    if ((Get-StringHash256 $found['message']['content']) -ne "$($Entry['prompt_sha256'])") { $p += 'The prompt in the transcript does not match the captured decision.' }
    return , $p
}

# Why ledger entry $Seq must not be applied (empty = it may). Shared by decide and revise.
function Get-EvidenceReasons([string]$RunDir, $State, $Ledger, [int]$Seq) {
    $a = $State.steps.approval
    $entry = $Ledger.lines[$Seq - 1] | ConvertFrom-Json -AsHashtable
    $decision = "$($entry['decision'])"
    $planSha = Get-InputHash (Join-Path $RunDir 'plan.md')
    $reasons = @()
    $earlier = @($Ledger.lines | Select-Object -First ($Seq - 1) | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
    if (@($earlier | Where-Object { "$($_['prompt_id'])" -eq "$($entry['prompt_id'])" }).Count -gt 0) { $reasons += "Replayed evidence: prompt '$($entry['prompt_id'])' was already used by an earlier decision." }
    if ($a.status -eq 'rejected') { $reasons += 'The plan was rejected; rejection is final for this run.' }
    elseif ($a.status -eq 'approved' -and $decision -eq 'approve') { $reasons += 'The current plan is already approved.' }
    $blockers = Get-ApprovalBlockers $State
    foreach ($b in $blockers) { $reasons += "The plan cannot be decided on now: $b." }
    if ($entry['plan_sha256'] -ne $planSha) { $reasons += "Stale evidence: it is for plan $("$($entry['plan_sha256'])".Substring(0, 12)), but the current plan is $(if ($planSha) { $planSha.Substring(0, 12) } else { 'missing' })." }
    elseif ($State.steps.plan.artifact_sha256 -ne $planSha) { $reasons += 'The current plan.md is not the accepted plan.' }
    if ("$($entry['plan_version'])" -ne "$($State.steps.plan['version'])") { $reasons += "Stale evidence: it is for plan version $($entry['plan_version']), but the current version is $($State.steps.plan['version'])." }
    $origin = Get-PromptOriginProblems $entry
    foreach ($o in $origin) { $reasons += $o }
    return , $reasons
}

# Marks ledger entry $Seq consumed (applied or refused); it can never be applied again.
function Add-ConsumedDecision($A, $Ledger, [int]$Seq, [string[]]$Reasons, [string]$Via) {
    $entry = $Ledger.lines[$Seq - 1] | ConvertFrom-Json -AsHashtable
    $record = [ordered]@{
        seq = $Seq; decision_id = $entry['decision_id']; decision = "$($entry['decision'])"; entry_sha256 = $Ledger.shas[$Seq - 1]
        plan_sha256 = $entry['plan_sha256']; plan_version = $entry['plan_version']; prompt_sha256 = $entry['prompt_sha256']
        outcome = $(if ($Reasons.Count) { 'refused' } else { 'applied' }); reasons = $Reasons; via = $Via; at = (Get-Now)
    }
    $A.consumed_through = $Seq
    $A.consumed_sha256 = Get-LedgerPrefixSha $Ledger $Seq
    $A.decisions = @(Get-List $A['decisions']) + @($record)
    if ($Reasons.Count) { $A.history += @([ordered]@{ result = 'decision_refused'; decision_id = $record.decision_id; decision = $record.decision; reasons = $Reasons; at = $record.at }) }
    return $record
}

# Ends the recorded decision: approval.json moves to approval/history/ for traceability.
function Reset-Approval([string]$RunDir, $A, [string]$Result, [string[]]$Reasons) {
    $path = Get-ArtifactPath $RunDir $A
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $dir = Join-Path $RunDir 'approval/history'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfff')
        Move-Item -LiteralPath $path -Destination (Join-Path $dir "$($A.decision_id)-$Result-$stamp.json") -Force
    }
    $A.history += @([ordered]@{ result = $Result; decision_id = $A.decision_id; decision = $A.decision; plan_sha256 = $A.plan_sha256; reasons = $Reasons; at = (Get-Now) })
    Clear-ApprovalDecision $A
}

function Clear-ApprovalDecision($A) {
    $A.status = 'pending'
    $A.artifact_sha256 = $null
    foreach ($k in 'decision', 'decision_id', 'ledger_seq', 'ledger_entry_sha256', 'plan_sha256', 'plan_version', 'plan_validation_sha256') { $A[$k] = $null }
}

# Keeps the approval and render steps consistent with the plan on every save. An approval is
# void as soon as the plan or its validation is no longer the approved one, the chain is not
# passed, or a revision is open. A manually modified file (an integrity violation, in
# $Violations) is not a legitimate change: it blocks the run but is never propagated.
function Update-Approval([string]$RunDir, $State, $Violations = @()) {
    Initialize-ApprovalSteps $State
    if (-not $State.steps.Contains('approval')) { return }
    $a = $State.steps.approval
    $ignore = @($Violations | ForEach-Object { $_.artifact.Substring("runs/$RunId/".Length) })

    if ($a.status -eq 'approved') {
        $blockers = Get-ApprovalBlockers $State
        $reasons = @($blockers)
        if ('plan.md' -notin $ignore -and (Get-InputHash (Join-Path $RunDir 'plan.md')) -ne $a.plan_sha256) { $reasons += 'plan.md is not the approved plan' }
        if ('validation/plan.json' -notin $ignore -and (Get-InputHash (Join-Path $RunDir 'validation/plan.json')) -ne $a.plan_validation_sha256) { $reasons += 'validation/plan.json is not the report the plan was approved with' }
        if ($reasons.Count -gt 0) { Reset-Approval $RunDir $a 'invalidated' $reasons }
    }
    if ($a.status -in 'pending', 'awaiting_decision') {
        # After a discard, the step is pending but may still carry the old decision's fields.
        if ($a.decision) { Clear-ApprovalDecision $a }
        $blockers = Get-ApprovalBlockers $State
        $a.status = if ($blockers.Count -eq 0) { 'awaiting_decision' } else { 'pending' }
    }

    $r = $State.steps['render']
    if ($r.status -in 'passed', 'failed' -and $r.inputs_sha256) {
        $reasons = @()
        if ($a.status -ne 'approved') { $reasons += "approval is $($a.status)" }
        foreach ($k in 'plan.md', 'approval.json') {
            if ($k -notin $ignore -and (Get-InputHash (Join-Path $RunDir $k)) -ne $r.inputs_sha256[$k]) { $reasons += "$k changed" }
        }
        if ($reasons.Count -gt 0) { Reset-Invalidated $r $reasons }
    }
}

# Problems with the recorded approval (empty = valid). Everything is recomputed from disk and
# cross-checked: state.json, approval.json, and the consumed ledger entry must all agree with
# the current plan. A hand-written approval.json, or a state.json edited to say "approved",
# fails this check unless a consumed ledger entry backs it.
function Test-ApprovalValid([string]$RunDir, $State) {
    $p = [System.Collections.Generic.List[string]]::new()
    $a = $State.steps['approval']
    if (-not $a) { $p.Add('This run has no approval step.'); return , $p }
    if ($a.status -ne 'approved') { $p.Add("Approval is '$($a.status)', not approved."); return , $p }

    $path = Get-ArtifactPath $RunDir $a
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $p.Add('approval.json is missing.'); return , $p }
    if ((Get-FileHash256 $path) -ne $a.artifact_sha256) { $p.Add('approval.json is not the recorded approval.') }
    try { $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable } catch { $doc = $null }
    if ($doc -isnot [System.Collections.IDictionary]) { $p.Add('approval.json is not a JSON object.') }
    else {
        if ($doc['decision'] -ne 'approved') { $p.Add("approval.json records '$($doc['decision'])', not approved.") }
        foreach ($k in 'decision_id', 'plan_sha256', 'ledger_entry_sha256') { if ("$($doc[$k])" -ne "$($a[$k])") { $p.Add("approval.json '$k' does not match the recorded decision.") } }
    }

    $ledger = Read-Ledger $RunDir
    $seq = [int]$a.ledger_seq
    if ($seq -lt 1 -or $seq -gt [int]$a.consumed_through -or $ledger.lines.Count -lt $seq) { $p.Add('No consumed ledger entry backs this approval.') }
    else {
        $partial = [ordered]@{ lines = @($ledger.lines | Select-Object -First $seq); shas = @($ledger.shas | Select-Object -First $seq) }
        $ledgerProblems = Get-LedgerProblems $partial
        foreach ($x in $ledgerProblems) { $p.Add("Ledger: $x") }
        if ($ledger.shas[$seq - 1] -ne $a.ledger_entry_sha256) { $p.Add('The ledger entry is not the one the approval was recorded from.') }
        try { $entry = $ledger.lines[$seq - 1] | ConvertFrom-Json -AsHashtable } catch { $entry = $null }
        if (-not $entry -or $entry['decision'] -ne 'approve' -or $entry['plan_sha256'] -ne $a.plan_sha256) { $p.Add('The ledger entry does not approve this plan.') }
    }

    $blockers = Get-ApprovalBlockers $State
    foreach ($b in $blockers) { $p.Add("Not approvable: $b.") }
    $planSha = Get-InputHash (Join-Path $RunDir 'plan.md')
    if ($planSha -ne $a.plan_sha256) { $p.Add('plan.md is not the approved plan.') }
    if ($State.steps.plan.artifact_sha256 -ne $a.plan_sha256) { $p.Add('The accepted plan is not the approved plan.') }
    $pv = $State.steps.'plan-validation'
    if (-not $pv.inputs_sha256 -or $pv.inputs_sha256['plan.md'] -ne $a.plan_sha256) { $p.Add('The plan validation was not run on the approved plan.') }
    if ((Get-InputHash (Join-Path $RunDir 'validation/plan.json')) -ne $a.plan_validation_sha256 -or $pv.artifact_sha256 -ne $a.plan_validation_sha256) { $p.Add('validation/plan.json is not the report the plan was approved with.') }
    $violations = Get-IntegrityViolations $RunDir $State
    foreach ($v in $violations) { $p.Add("Integrity violation: $($v.step).") }
    return , $p
}

# Derive workflow_status / current_step / next_step from the steps, so they can't drift.
function Update-Workflow($State) {
    $steps = $State.steps
    $req = $steps.requirements
    $research = @(Get-ResearchStepNames $State | ForEach-Object { $steps[$_] })
    $State.failed_steps = @($steps.Keys | Where-Object { Test-Exhausted $steps[$_] })
    $State.next_step = $null
    $State.current_step = $null

    if ($State['integrity'] -and $State.integrity.status -eq 'violated') {
        $State.workflow_status = 'blocked'
        $State.next_step = "resolve integrity violation ($(@($State.integrity.violations | ForEach-Object { $_.step }) -join ', '))"
        return
    }

    if ($req.status -ne 'passed') {
        $State.workflow_status = if (Test-Exhausted $req) { 'failed' } else { 'in_progress' }
        $State.current_step = 'requirements'
        return
    }
    if ($research.Count -eq 0) {
        $State.workflow_status = 'paused'
        $State.next_step = 'research-selection'
        return
    }
    if (@($research | Where-Object { $_.status -ne 'passed' -and -not (Test-Exhausted $_) }).Count -gt 0) {
        # At least one research step is pending, running, or retryable.
        $State.workflow_status = 'in_progress'
        $State.current_step = 'research'
        return
    }
    if (@($research | Where-Object { Test-Exhausted $_ }).Count -gt 0) {
        $State.workflow_status = 'failed'
        return
    }
    if (-not $steps.Contains('coverage')) {
        # Run selected before the downstream steps existed.
        $State.workflow_status = 'paused'
        $State.next_step = 'synthesis (not supported for this run)'
        return
    }
    foreach ($name in $DownstreamSteps.Keys) {
        $entry = $steps[$name]
        if ($entry.status -eq 'passed') { continue }
        $State.workflow_status = if (Test-Exhausted $entry) { 'failed' } else { 'in_progress' }
        $State.current_step = $name
        return
    }
    $approval = $steps['approval']
    switch ($approval.status) {
        'rejected' {
            # Final: nothing is rendered, revised, or decided again in this run.
            $State.workflow_status = 'rejected'
            return
        }
        'approved' {
            $render = $steps.render
            if ($render.status -eq 'passed') { $State.workflow_status = 'completed'; return }
            if (Test-Exhausted $render) { $State.workflow_status = 'failed'; return }
            if ($render.status -in 'running', 'failed') { $State.workflow_status = 'in_progress'; $State.current_step = 'render'; return }
            $State.workflow_status = 'approved'
            $State.next_step = 'render (not implemented yet)'
        }
        default {
            $State.workflow_status = 'awaiting_approval'
            $State.current_step = 'approval'
            $State.next_step = "approval: the user's decision on the current plan (approve, request changes, or reject)"
        }
    }
}

# ---------------------------------------------------------------- gates

# Requirements and research artifacts. Returns the list of gate problems (empty = passed).
function Test-Artifact([string]$RunDir, $State, $Entry) {
    $problems = [System.Collections.Generic.List[string]]::new()
    $path = Get-ArtifactPath $RunDir $Entry
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $problems.Add("Artifact not found: $($Entry.artifact)"); return , $problems }
    try { $content = Get-Content -LiteralPath $path -Raw -Encoding utf8 }
    catch { $problems.Add("Artifact not readable: $($_.Exception.Message)"); return , $problems }
    if (-not "$content".Trim()) { $problems.Add('Artifact is empty.'); return , $problems }
    $lines = @($content -split "`r?`n" | ForEach-Object { $_.TrimEnd() })

    # Dependency invalidation (CLAUDE.md §5.2): inputs must not change during the attempt.
    $inputHash = Get-InputHash (Join-Path $RunDir 'confirmed-input.md')
    if ($Step -eq 'requirements') {
        foreach ($h in $RequirementsHeadings) { if ($lines -notcontains $h) { $problems.Add("Missing heading: '$h'") } }
        if (-not ($lines -match '^blocking_open_questions:\s*\d+$')) { $problems.Add("Missing or non-numeric front-matter field: 'blocking_open_questions'") }
        $fm = Get-FrontMatter $lines
        $mandatory = @($fm['mandatory_topics'] | Where-Object { "$_".Trim() })
        if ($mandatory.Count -eq 0) { $problems.Add("Front matter needs a non-empty 'mandatory_topics' list") }
        $gapText = ((@(Get-SectionLines $lines '## Knowledge Gaps') + @(Get-SectionLines $lines '## Topics')) -join "`n").ToLowerInvariant()
        $seen = @{}
        foreach ($t in $mandatory) {
            if ($seen.ContainsKey($t.ToLowerInvariant())) { $problems.Add("Mandatory topic '$t' is listed twice") }
            $seen[$t.ToLowerInvariant()] = $true
            if (-not $gapText.Contains($t.ToLowerInvariant())) { $problems.Add("Mandatory topic '$t' does not appear under '## Knowledge Gaps' or '## Topics'") }
        }
        $budget = "$($fm['time_budget_hours'])"
        if ($budget -ne 'unspecified' -and -not (Test-Number $budget)) { $problems.Add("Front-matter 'time_budget_hours' must be a positive number or 'unspecified' (got '$budget')") }
        if ($inputHash -ne $Entry.input_sha256) { $problems.Add('Stale: confirmed-input.md changed after this attempt started') }
        return , $problems
    }

    $spec = $ResearchAreas[$Entry.area]
    if (-not ($lines -match '^# Research: \S')) { $problems.Add("Missing title heading '# Research: <area name>'") }
    foreach ($h in $ResearchHeadings) { if ($lines -notcontains $h) { $problems.Add("Missing heading: '$h'") } }
    if ($lines -notcontains "generated_by: $($spec.agent)") { $problems.Add("Missing front-matter line 'generated_by: $($spec.agent)'") }
    foreach ($t in $Entry.topics) {
        if ($lines -notcontains "### $t") { $problems.Add("Assigned topic not covered: missing heading '### $t'") }
    }
    $urls = Get-SectionUrls $lines '## Sources'
    if ($urls.Count -lt $MinResearchSources) { $problems.Add("'## Sources' lists $($urls.Count) distinct URL(s); at least $MinResearchSources required") }
    if ($spec.require_ms_learn -and -not ($urls -match '^https://learn\.microsoft\.com/')) {
        $problems.Add("'## Sources' has no Microsoft Learn URL (https://learn.microsoft.com/...)")
    }
    if ($inputHash -ne $Entry.inputs_sha256.confirmed_input) { $problems.Add('Stale: confirmed-input.md changed after this attempt started') }
    $reqHash = Get-InputHash (Get-ArtifactPath $RunDir $State.steps.requirements)
    if ($reqHash -ne $Entry.inputs_sha256.requirements) { $problems.Add('Stale: requirements.md changed after this attempt started') }
    return , $problems
}

# plan.md (owner: study-planner). Returns the list of gate problems (empty = passed).
function Test-Plan([string]$RunDir, $State, $Entry) {
    $problems = [System.Collections.Generic.List[string]]::new()
    $path = Get-ArtifactPath $RunDir $Entry
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $problems.Add("Artifact not found: $($Entry.artifact)"); return , $problems }
    $lines = Get-Lines $path
    if (-not (($lines -join '').Trim())) { $problems.Add('Artifact is empty.'); return , $problems }
    $fm = Get-FrontMatter $lines
    $req = $State.steps.requirements
    $mandatory = @($req.mandatory_topics)

    # Structure.
    if ("$($fm['generated_by'])" -ne 'study-planner') { $problems.Add("Front matter needs 'generated_by: study-planner'") }
    if (-not ($lines -match '^# Study Plan')) { $problems.Add("Missing title heading '# Study Plan...'") }
    foreach ($h in $PlanHeadings) { if ($lines -notcontains $h) { $problems.Add("Missing heading: '$h'") } }

    # Referenced research artifacts exist and match the selection.
    $expected = @(Get-ResearchStepNames $State | ForEach-Object { "research/$($State.steps[$_].area).md" })
    $declared = @($fm['research_inputs'] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    foreach ($d in $declared) {
        if ($d -notin $expected) { $problems.Add("research_inputs lists '$d', which is not a selected research artifact") }
        elseif (-not (Test-Path -LiteralPath (Join-Path $RunDir $d) -PathType Leaf)) { $problems.Add("research_inputs lists '$d', which does not exist") }
    }
    foreach ($e in $expected) { if ($e -notin $declared) { $problems.Add("research_inputs is missing '$e'") } }

    # Every mandatory topic has a Topic Plans section with at least one source link.
    $topicPlans = @(Get-SectionLines $lines '## Topic Plans')
    foreach ($t in $mandatory) {
        if ($topicPlans -notcontains "### $t") { $problems.Add("Mandatory topic missing from '## Topic Plans': no heading '### $t'"); continue }
        if ((Get-Urls @(Get-SectionLines $topicPlans "### $t")).Count -eq 0) { $problems.Add("Topic plan '### $t' cites no source URL") }
    }

    # Schedule table: minutes, activities, budget.
    $rows = @(Get-SectionLines $lines '## Schedule' | Where-Object { $_ -match '^\s*\|' })
    $cells = { param($row) @($row.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }) }
    $totalMinutes = 0
    $activitiesByTopic = @{}
    $hasRevision = $false
    if ($rows.Count -lt 3) { $problems.Add("'## Schedule' needs a Markdown table with a header and at least one session row") }
    else {
        $header = @(& $cells $rows[0] | ForEach-Object { $_.ToLowerInvariant() })
        $iTopic = [array]::IndexOf($header, 'topic'); $iAct = [array]::IndexOf($header, 'activities'); $iMin = [array]::IndexOf($header, 'minutes')
        if ($iTopic -lt 0 -or $iAct -lt 0 -or $iMin -lt 0) { $problems.Add("'## Schedule' table header needs 'Topic', 'Activities', and 'Minutes' columns") }
        else {
            foreach ($row in $rows[1..($rows.Count - 1)]) {
                if ($row -match '^\s*\|\s*:?-{3,}') { continue }
                $c = & $cells $row
                $minutes = if ($c.Count -gt $iMin) { $c[$iMin] } else { '' }
                if ($minutes -notmatch '^\d+$' -or [int]$minutes -le 0) { $problems.Add("Schedule row has a non-positive or non-integer Minutes value: '$row'"); continue }
                $totalMinutes += [int]$minutes
                $acts = @(($c[$iAct] -split '[,;/]') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
                foreach ($a in $acts) { if ($a -notin $PlanActivities) { $problems.Add("Schedule row has unknown activity '$a' (allowed: $($PlanActivities -join ', '))") } }
                if ($acts -contains 'revision') { $hasRevision = $true }
                foreach ($topic in ($c[$iTopic] -split ';') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }) {
                    if (-not $activitiesByTopic.ContainsKey($topic)) { $activitiesByTopic[$topic] = @() }
                    $activitiesByTopic[$topic] += $acts
                }
            }
        }
    }
    foreach ($t in $mandatory) {
        $acts = @($activitiesByTopic[$t.ToLowerInvariant()])
        foreach ($need in 'theory', 'practice', 'interview') {
            if ($acts -notcontains $need) { $problems.Add("Schedule has no '$need' session for mandatory topic '$t'") }
        }
    }
    if (-not $hasRevision) { $problems.Add("Schedule has no 'revision' session") }

    $totalHours = [math]::Round($totalMinutes / 60, 2)
    $budget = "$($fm['budget_hours'])"
    $planned = "$($fm['planned_hours'])"
    $confirmed = $req.time_budget_hours
    if (-not (Test-Number $budget)) { $problems.Add("Front matter needs a positive numeric 'budget_hours' (got '$budget')") }
    else {
        if ($null -ne $confirmed -and [double]$budget -ne [double]$confirmed) { $problems.Add("budget_hours $budget differs from the confirmed time_budget_hours $confirmed") }
        if ($totalHours -gt [double]$budget) { $problems.Add("Over budget: schedule totals $totalHours h ($totalMinutes min), budget is $budget h") }
    }
    if (-not (Test-Number $planned) -or [math]::Abs([double]$planned - $totalHours) -gt 0.05) { $problems.Add("planned_hours '$planned' does not match the schedule total of $totalHours h") }

    # Every URL must be traceable to a selected research artifact.
    $known = @{}
    foreach ($e in $expected) {
        $p = Join-Path $RunDir $e
        if (Test-Path -LiteralPath $p) { foreach ($u in Get-Urls (Get-Lines $p)) { $known[(Get-NormalizedUrl $u)] = $true } }
    }
    foreach ($u in Get-Urls $lines) {
        if (-not $known.ContainsKey((Get-NormalizedUrl $u))) { $problems.Add("Untraceable source: $u does not appear in any research artifact") }
    }
    $Entry.planned_hours = $totalHours
    return , $problems
}

# Validator report (coverage or plan). Returns schema problems (owner: quality-validator)
# and the blocking findings to route, plus coverage's deterministic findings.
function Test-ValidatorReport([string]$RunDir, $State, [string]$Name) {
    $spec = $DownstreamSteps[$Name]
    $problems = [System.Collections.Generic.List[string]]::new()
    $blocking = [System.Collections.Generic.List[object]]::new()
    $result = @{ Problems = $problems; Blocking = $blocking }
    $path = Join-Path $RunDir $spec.artifact
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $problems.Add("Report not found: $($spec.artifact)"); return $result }
    try { $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable }
    catch { $problems.Add("Report is not valid JSON: $($_.Exception.Message)"); return $result }
    if ($report -isnot [System.Collections.IDictionary]) { $problems.Add('Report must be a JSON object'); return $result }
    $summary = Join-Path $RunDir $spec.summary
    if (-not (Test-Path -LiteralPath $summary -PathType Leaf) -or -not (Get-Content -LiteralPath $summary -Raw).Trim()) { $problems.Add("Human-readable summary missing or empty: $($spec.summary)") }

    if ("$($report['generated_by'])" -ne 'quality-validator') { $problems.Add("'generated_by' must be 'quality-validator'") }
    if ("$($report['report'])" -ne $spec.report) { $problems.Add("'report' must be '$($spec.report)'") }
    if ("$($report['run_id'])" -ne $RunId) { $problems.Add("'run_id' must be '$RunId'") }
    $verdict = "$($report['verdict'])"
    if ($verdict -notin 'pass', 'fail') { $problems.Add("'verdict' must be 'pass' or 'fail'") }

    $selectedAgents = @(Get-ResearchStepNames $State | ForEach-Object { $State.steps[$_].agent })
    $owners = @($selectedAgents) + @('quality-validator') + $NonRetryableOwners
    if ($Name -eq 'plan-validation') { $owners += 'study-planner' }

    $findings = @($report['findings'] | Where-Object { $null -ne $_ })
    if ($report['findings'] -isnot [System.Collections.IList] -and $null -ne $report['findings']) { $problems.Add("'findings' must be an array") }
    $i = 0
    foreach ($f in $findings) {
        $i++
        $id = if ($f['id']) { $f['id'] } else { "#$i" }
        if ("$($f['severity'])" -notin 'blocking', 'advisory') { $problems.Add("Finding $id 'severity' must be 'blocking' or 'advisory'") }
        if ("$($f['category'])" -notin $FindingCategories) { $problems.Add("Finding $id has unknown 'category' '$($f['category'])'") }
        if ("$($f['owner'])" -notin $owners) { $problems.Add("Finding $id 'owner' must be one of: $($owners -join ', ') (got '$($f['owner'])')") }
        if (-not "$($f['message'])".Trim()) { $problems.Add("Finding $id needs a 'message'") }
        if ($f['severity'] -eq 'blocking' -and $f['category'] -eq 'optional_topic') { $problems.Add("Finding ${id}: an optional topic can never be blocking") }
        if ($f['severity'] -eq 'blocking') { $blocking.Add([ordered]@{ id = $id; owner = "$($f['owner'])"; category = "$($f['category'])"; topic = $f['topic']; message = "$($f['message'])"; fix = $f['fix'] }) }
    }

    # Every mandatory topic is assessed exactly once; anything not covered must be blocking.
    $mandatory = @($State.steps.requirements.mandatory_topics)
    $statuses = @{}
    foreach ($m in @($report['mandatory_topics'] | Where-Object { $null -ne $_ })) {
        $key = "$($m['topic'])".ToLowerInvariant()
        if ($statuses.ContainsKey($key)) { $problems.Add("Mandatory topic '$($m['topic'])' is assessed more than once") }
        $statuses[$key] = "$($m['status'])"
        if ("$($m['status'])" -notin 'covered', 'partial', 'missing') { $problems.Add("Mandatory topic '$($m['topic'])' status must be covered, partial, or missing") }
    }
    foreach ($t in $mandatory) {
        $key = $t.ToLowerInvariant()
        if (-not $statuses.ContainsKey($key)) { $problems.Add("Report does not assess mandatory topic '$t'"); continue }
        if ($statuses[$key] -ne 'covered' -and -not ($blocking | Where-Object { "$($_.topic)".ToLowerInvariant() -eq $key })) {
            $problems.Add("Mandatory topic '$t' is '$($statuses[$key])' but has no blocking finding")
        }
    }
    foreach ($k in $statuses.Keys) { if ($k -notin @($mandatory | ForEach-Object { $_.ToLowerInvariant() })) { $problems.Add("Report assesses '$k', which is not a confirmed mandatory topic; list optional topics under 'optional_recommendations'") } }

    if ($verdict -eq 'pass' -and $blocking.Count -gt 0) { $problems.Add("'verdict' is 'pass' but there are $($blocking.Count) blocking finding(s)") }
    if ($verdict -eq 'fail' -and $blocking.Count -eq 0) { $problems.Add("'verdict' is 'fail' but there is no blocking finding") }

    # Deterministic coverage: every mandatory topic's mapped research topics have a section.
    if ($Name -eq 'coverage') {
        foreach ($c in @($State.research.coverage)) {
            foreach ($rt in @($c.research_topics)) {
                $owner = $State.research.topic_owner[$rt]
                $stepName = @(Get-ResearchStepNames $State | Where-Object { $State.steps[$_].agent -eq $owner })[0]
                $file = Join-Path $RunDir "research/$($State.steps[$stepName].area).md"
                if (-not (Test-Path -LiteralPath $file) -or (Get-Lines $file) -notcontains "### $rt") {
                    $blocking.Add([ordered]@{ id = 'D-coverage'; owner = $owner; category = 'missing_coverage'; topic = $c.mandatory_topic; message = "Mandatory topic '$($c.mandatory_topic)' maps to research topic '$rt', but research/$($State.steps[$stepName].area).md has no '### $rt' section"; fix = "Add a '### $rt' section" })
                }
            }
        }
    }
    return $result
}

# Copy the validator's report into validation/history/ so every attempt stays traceable.
function Save-ReportHistory([string]$RunDir, [string]$Name, $Entry) {
    $spec = $DownstreamSteps[$Name]
    $dir = Join-Path $RunDir 'validation/history'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfff')
    foreach ($rel in $spec.artifact, $spec.summary) {
        $src = Join-Path $RunDir $rel
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($rel)
            Copy-Item -LiteralPath $src -Destination (Join-Path $dir "$Name-attempt$($Entry.attempts)-$stamp$ext") -Force
        }
    }
}

function Set-AttemptFailed($Entry, [string[]]$Reasons, [string]$Gate) {
    $now = Get-Now
    $Entry.status = 'failed'
    $Entry.completed_at = $now
    $h = [ordered]@{ attempt = $Entry.attempts; version = (Get-NextVersion $Entry); result = 'failed'; reasons = $Reasons; at = $now }
    if ($Gate) { $h.gate = $Gate }
    if ($Entry['active_revision']) { $h.revision = $Entry.active_revision }
    $Entry.history += @($h)
}

# ---------------------------------------------------------------- actions

# The lock handle is disposed in `finally`, so it is released even when the script is invoked
# in-process (`& state.ps1`), not only when the pwsh process exits.
$lock = $null
try {
    switch ($Action) {
        'init' {
            $slug = ($Label.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
            if (-not $slug) { $slug = 'run' }
            if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).TrimEnd('-') }
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
            $suffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
            $RunId = "$stamp-$slug-$suffix"

            New-Item -ItemType Directory -Path $RunsRoot -Force | Out-Null
            $runDir = Join-Path $RunsRoot $RunId
            New-Item -ItemType Directory -Path $runDir | Out-Null   # fails if it already exists

            $now = Get-Now
            $state = [ordered]@{
                schema_version  = 2
                run_id          = $RunId
                workflow_status = 'in_progress'
                current_step    = 'requirements'
                created_at      = $now
                updated_at      = $now
                inputs          = [ordered]@{ confirmed_input = "runs/$RunId/confirmed-input.md" }
                research        = $null
                steps           = [ordered]@{
                    requirements = [ordered]@{
                        status          = 'pending'
                        agent           = 'requirements-formalizer'
                        artifact        = "runs/$RunId/requirements.md"
                        attempts        = 0
                        max_attempts    = $MaxAttempts
                        input_sha256    = $null
                        artifact_sha256 = $null
                        agent_id        = $null
                        started_at      = $null
                        completed_at    = $null
                        history         = @()
                    }
                }
            }
            Save-State $runDir $state
            [ordered]@{
                run_id            = $RunId
                run_dir           = "runs/$RunId"
                state_path        = "runs/$RunId/state.json"
                confirmed_input   = "runs/$RunId/confirmed-input.md"
                requirements_path = "runs/$RunId/requirements.md"
            } | ConvertTo-Json
        }

        'select' {
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            Assert-Integrity $runDir $state
            if ($state.steps.requirements.status -ne 'passed') { throw 'Requirements step must pass before research selection.' }
            if ($state['research']) { throw "Research agents were already selected for run '$RunId'." }
            if (-not $SelectionFile -or -not (Test-Path -LiteralPath $SelectionFile -PathType Leaf)) { throw "Selection file not found: '$SelectionFile'." }

            $sel = Get-Content -LiteralPath $SelectionFile -Raw | ConvertFrom-Json -AsHashtable
            $selected = @($sel['selected'] | Where-Object { $_ })
            $notSelected = @($sel['not_selected'] | Where-Object { $_ })
            $byAgent = @{}
            foreach ($area in $ResearchAreas.Keys) { $byAgent[$ResearchAreas[$area].agent] = $area }

            $errors = [System.Collections.Generic.List[string]]::new()
            if ($selected.Count -eq 0) { $errors.Add("'selected' must contain at least one agent.") }
            $seenAgents = @{}
            $topicOwner = [ordered]@{}
            foreach ($s in $selected + $notSelected) {
                $agent = "$($s['agent'])"
                if (-not $byAgent.ContainsKey($agent)) { $errors.Add("Unknown research agent '$agent'."); continue }
                if ($seenAgents.ContainsKey($agent)) { $errors.Add("Agent '$agent' listed more than once.") }
                $seenAgents[$agent] = $true
                if (-not "$($s['reason'])".Trim()) { $errors.Add("Agent '$agent' needs a non-empty 'reason'.") }
            }
            foreach ($s in $selected) {
                $topics = @($s['topics'] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
                if ($topics.Count -eq 0) { $errors.Add("Selected agent '$($s['agent'])' needs at least one topic.") }
                foreach ($t in $topics) {
                    if ($t -match '[\r\n]') { $errors.Add("Topic '$t' must be a single line.") }
                    if (@($topicOwner.Keys | Where-Object { $_.ToLowerInvariant() -eq $t.ToLowerInvariant() }).Count -gt 0) { $errors.Add("Topic '$t' is assigned to more than one agent.") }
                    else { $topicOwner[$t] = "$($s['agent'])" }
                }
            }
            foreach ($agent in $byAgent.Keys) {
                if (-not $seenAgents.ContainsKey($agent)) { $errors.Add("Agent '$agent' must appear in 'selected' or 'not_selected' (with a reason).") }
            }

            # Every confirmed mandatory topic must map to at least one assigned research topic.
            $mandatory = @($state.steps.requirements.mandatory_topics)
            $coverage = @($sel['coverage'] | Where-Object { $_ })
            $mapped = @{}
            foreach ($c in $coverage) {
                $mt = "$($c['mandatory_topic'])".Trim()
                if (-not (@($mandatory | Where-Object { $_ -eq $mt }).Count)) { $errors.Add("Coverage entry '$mt' is not a confirmed mandatory topic (exact text from requirements.md front matter).") ; continue }
                if ($mapped.ContainsKey($mt)) { $errors.Add("Mandatory topic '$mt' appears more than once in 'coverage'.") }
                $rts = @($c['research_topics'] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
                if ($rts.Count -eq 0) { $errors.Add("Mandatory topic '$mt' must map to at least one research topic.") }
                foreach ($rt in $rts) { if (-not $topicOwner.Contains($rt)) { $errors.Add("Mandatory topic '$mt' maps to '$rt', which is not a topic assigned to a selected agent.") } }
                $mapped[$mt] = $rts
            }
            foreach ($mt in $mandatory) {
                if (-not $mapped.ContainsKey($mt)) { $errors.Add("Mandatory topic '$mt' is not covered by any selected research agent. Stop and tell the user; do not plan without research.") }
            }
            if ($errors.Count -gt 0) { [ordered]@{ result = 'invalid'; errors = $errors } | ConvertTo-Json; exit 1 }

            $now = Get-Now
            $state.research = [ordered]@{
                selected_at      = $now
                selection_file   = (Resolve-Path -LiteralPath $SelectionFile -Relative).Replace('\', '/') -replace '^\./', ''
                selection_sha256 = Get-FileHash256 $SelectionFile
                selected_agents  = @()
                not_selected     = @($notSelected | ForEach-Object { [ordered]@{ agent = $_['agent']; reason = $_['reason'] } })
                coverage         = @($mandatory | ForEach-Object { [ordered]@{ mandatory_topic = $_; research_topics = $mapped[$_] } })
                topic_owner      = $topicOwner
            }
            New-Item -ItemType Directory -Path (Join-Path $runDir 'research') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $runDir 'validation') -Force | Out-Null
            foreach ($s in $selected) {
                $area = $byAgent["$($s['agent'])"]
                $stepName = "research-$area"
                $topics = @($s['topics'] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
                $artifact = "runs/$RunId/research/$area.md"
                $state.research.selected_agents += @([ordered]@{ agent = $s['agent']; area = $area; step = $stepName; topics = $topics; reason = $s['reason']; artifact = $artifact })
                $state.steps[$stepName] = [ordered]@{
                    status          = 'pending'
                    agent           = $s['agent']
                    area            = $area
                    topics          = $topics
                    artifact        = $artifact
                    attempts        = 0
                    max_attempts    = $MaxAttempts
                    inputs_sha256   = $null
                    artifact_sha256 = $null
                    agent_id        = $null
                    started_at      = $null
                    completed_at    = $null
                    history         = @()
                }
            }
            foreach ($name in $DownstreamSteps.Keys) {
                $spec = $DownstreamSteps[$name]
                $state.steps[$name] = [ordered]@{
                    status          = 'pending'
                    agent           = $spec.agent
                    artifact        = "runs/$RunId/$($spec.artifact)"
                    attempts        = 0
                    max_attempts    = $MaxAttempts
                    inputs_sha256   = $null
                    artifact_sha256 = $null
                    agent_id        = $null
                    started_at      = $null
                    completed_at    = $null
                    history         = @()
                }
                if ($spec.summary) { $state.steps[$name].summary = "runs/$RunId/$($spec.summary)" }
            }
            Save-State $runDir $state
            [ordered]@{
                run_id   = $RunId
                result   = 'selected'
                steps    = @($state.research.selected_agents | ForEach-Object { [ordered]@{ step = $_.step; agent = $_.agent; artifact = $_.artifact; topics = $_.topics } })
                skipped  = @($state.research.not_selected | ForEach-Object { $_.agent })
                coverage = $state.research.coverage
            } | ConvertTo-Json -Depth 5
        }

        'start' {
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            $entry = Get-StepEntry $state
            if ($Step -eq 'approval') {
                throw "Approval is not a step to start. Only the user decides: their decision is captured as ledger evidence ($LedgerPath) and applied with 'state.ps1 decide'."
            }
            # A manually modified upstream artifact must be resolved before anything builds on it.
            Assert-Integrity $runDir $state $Step
            # Apply pending invalidations first (an input may have changed since the last save),
            # so a stale passed step can be re-run instead of reporting "already passed".
            Update-Invalidation $runDir $state (Get-IntegrityViolations $runDir $state)
            if ($entry.status -eq 'passed') {
                $hint = if ($Step -in $RevisableSteps) { " To change it, record a user-requested revision with 'state.ps1 revise'." } else { '' }
                throw "Step '$Step' already passed.$hint"
            }
            if ($entry.status -eq 'running') { throw "Step '$Step' is already running (attempt $($entry.attempts)). Complete or fail it first." }

            if ($Step -eq 'render') {
                # Nothing is rendered without a recorded approval of exactly the current plan.
                $problems = Test-ApprovalValid $runDir $state
                if ($problems.Count -gt 0) { throw "Render refused: there is no valid approval of the current plan. $($problems -join ' ')" }
                if ($entry['retry_blocked']) { throw "Step '$Step' failed with a non-retryable error." }
                if ($entry.attempts -ge $MaxAttempts) { throw "Step '$Step' has used all $MaxAttempts attempts." }
                $entry.inputs_sha256 = [ordered]@{
                    'plan.md'       = Get-InputHash (Join-Path $runDir 'plan.md')
                    'approval.json' = Get-InputHash (Join-Path $runDir 'approval.json')
                }
                $entry.attempts += 1
                $entry.status = 'running'
                $entry.started_at = Get-Now
                $entry.completed_at = $null
                Save-State $runDir $state
                [ordered]@{ run_id = $RunId; step = $Step; attempt = $entry.attempts; max_attempts = $MaxAttempts; artifact = $entry.artifact; plan_sha256 = $state.steps.approval.plan_sha256 } | ConvertTo-Json
                return
            }

            $inputPath = Join-Path $runDir 'confirmed-input.md'
            if (-not (Test-Path -LiteralPath $inputPath)) { throw "Missing confirmed input: runs/$RunId/confirmed-input.md" }

            if ($Step -eq 'requirements') {
                if ($entry['retry_blocked']) { throw "Step '$Step' failed with a non-retryable error." }
                if ($entry.attempts -ge $MaxAttempts) { throw "Step '$Step' has used all $MaxAttempts attempts." }
                $entry.input_sha256 = Get-FileHash256 $inputPath
            }
            else {
                $req = $state.steps.requirements
                if ($req.status -ne 'passed') { throw 'Requirements step must pass before research starts.' }
                $reqHash = Get-FileHash256 (Get-ArtifactPath $runDir $req)
                if ($reqHash -ne $req.artifact_sha256) { throw 'requirements.md changed after it passed (stale). Re-run the requirements step first.' }
                $inputHash = Get-FileHash256 $inputPath
                if ($inputHash -ne $req.input_sha256) { throw 'confirmed-input.md changed after requirements were built from it (stale). Re-run the requirements step first.' }

                if ($DownstreamSteps.Contains($Step)) {
                    foreach ($p in Get-Prerequisites $state $Step) {
                        if ($state.steps[$p].status -ne 'passed') { throw "Input step '$p' is $($state.steps[$p].status); it must pass before '$Step' starts." }
                    }
                    $current = Get-DownstreamInputs $runDir $state $Step
                    foreach ($k in $current.Keys) { if (-not $current[$k]) { throw "Missing input file: runs/$RunId/$k" } }
                    if ($entry.inputs_sha256) {
                        $changed = @($current.Keys | Where-Object { $current[$_] -ne $entry.inputs_sha256[$_] } | ForEach-Object { "$_ changed" })
                        if ($changed.Count -gt 0) { Reset-Invalidated $entry $changed }
                    }
                    if ($entry['retry_blocked']) { throw "Step '$Step' failed with a non-retryable error." }
                    if ($entry.attempts -ge $MaxAttempts) { throw "Step '$Step' has used all $MaxAttempts attempts." }
                    $entry.inputs_sha256 = $current
                }
                else {
                    if ($entry['retry_blocked']) { throw "Step '$Step' failed with a non-retryable error." }
                    if ($entry.attempts -ge $MaxAttempts) { throw "Step '$Step' has used all $MaxAttempts attempts." }
                    $entry.inputs_sha256 = [ordered]@{
                        confirmed_input = $inputHash
                        requirements    = $reqHash
                        assignment      = Get-StringHash256 (@($entry.topics) -join "`n")
                    }
                }
            }

            $entry.attempts += 1
            $entry.status = 'running'
            $entry.started_at = Get-Now
            $entry.completed_at = $null
            Save-State $runDir $state
            [ordered]@{ run_id = $RunId; step = $Step; attempt = $entry.attempts; max_attempts = $MaxAttempts; artifact = $entry.artifact } | ConvertTo-Json
        }

        'complete' {
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            $entry = Get-StepEntry $state
            if ($entry.status -ne 'running') { throw "Step '$Step' is not running (status: $($entry.status))." }
            # Refused, not failed: the attempt stays running and is not counted.
            Assert-Integrity $runDir $state $Step
            if ($AgentId) { $entry.agent_id = $AgentId }

            if ($Step -eq 'render') {
                # The approval is checked again: it may have been voided during rendering.
                $validity = Test-ApprovalValid $runDir $state
                $stale = @($validity)
                foreach ($k in 'plan.md', 'approval.json') {
                    if ((Get-InputHash (Join-Path $runDir $k)) -ne $entry.inputs_sha256[$k]) { $stale += "$k changed during rendering" }
                }
                if ($stale.Count -gt 0) {
                    Reset-Invalidated $entry $stale
                    Save-State $runDir $state
                    [ordered]@{ run_id = $RunId; step = $Step; result = 'stale'; reasons = $stale; workflow_status = $state.workflow_status } | ConvertTo-Json -Depth 5
                    exit 1
                }
                $guide = Get-ArtifactPath $runDir $entry
                $approved = $state.steps.approval.plan_sha256
                $problems = @()
                if (-not (Test-Path -LiteralPath $guide -PathType Leaf)) { $problems += 'guide.html does not exist.' }
                else {
                    $html = Get-Content -LiteralPath $guide -Raw -Encoding utf8
                    $m = [regex]::Match("$html", '<meta\s+name="plan-sha256"\s+content="([0-9a-f]{64})"\s*/?>')
                    if (-not $m.Success) { $problems += 'guide.html has no <meta name="plan-sha256" content="..."> tag.' }
                    elseif ($m.Groups[1].Value -ne $approved) { $problems += "guide.html was rendered from plan $($m.Groups[1].Value.Substring(0, 12)), not the approved plan $($approved.Substring(0, 12))." }
                }
                if ($problems.Count -gt 0) {
                    Set-AttemptFailed $entry $problems
                    # The renderer wrote this file during its attempt: known output, not tampering.
                    if (Test-Path -LiteralPath $guide -PathType Leaf) { $entry.history[-1].output_sha256 = Get-FileHash256 $guide }
                    Save-State $runDir $state
                    [ordered]@{ run_id = $RunId; step = $Step; result = 'failed'; attempt = $entry.attempts; attempts_left = Get-AttemptsLeft $entry; problems = $problems; workflow_status = $state.workflow_status } | ConvertTo-Json -Depth 5
                    exit 1
                }
                $entry.status = 'passed'
                $entry.artifact_sha256 = Get-FileHash256 $guide
                $entry.completed_at = Get-Now
                $accepted = Add-AcceptedVersion $runDir $entry $Step
                $entry.history += @([ordered]@{ attempt = $entry.attempts; version = $accepted.version; result = 'passed'; plan_sha256 = $approved; at = $entry.completed_at })
                Save-State $runDir $state
                [ordered]@{ run_id = $RunId; step = $Step; result = 'passed'; attempt = $entry.attempts; version = $accepted.version; artifact = $entry.artifact; artifact_sha256 = $entry.artifact_sha256; plan_sha256 = $approved; workflow_status = $state.workflow_status } | ConvertTo-Json
                return
            }

            $isDownstream = $DownstreamSteps.Contains($Step)

            # Inputs that changed during the attempt invalidate it (not a failed attempt).
            if ($isDownstream) {
                $stale = Get-StaleReasons $runDir $state $Step
                if ($stale.Count -gt 0) {
                    Reset-Invalidated $entry $stale
                    Save-State $runDir $state
                    [ordered]@{ run_id = $RunId; step = $Step; result = 'stale'; reasons = $stale; workflow_status = $state.workflow_status } | ConvertTo-Json -Depth 5
                    exit 1
                }
            }

            $kind = if ($isDownstream) { $DownstreamSteps[$Step].kind } else { 'artifact' }
            $retry = @()
            $blocked = @()
            switch ($kind) {
                'artifact' { $problems = Test-Artifact $runDir $state $entry }
                'plan' { $problems = Test-Plan $runDir $state $entry }
                'report' {
                    Save-ReportHistory $runDir $Step $entry
                    $check = Test-ValidatorReport $runDir $state $Step
                    $problems = [System.Collections.Generic.List[string]]::new()
                    if ($check.Problems.Count -gt 0) {
                        # The report itself is unusable: retry only the validator.
                        foreach ($p in $check.Problems) { $problems.Add("Report problem: $p") }
                        $retry += [ordered]@{ step = $Step; owner = 'quality-validator'; feedback = @($check.Problems) }
                    }
                    elseif ($check.Blocking.Count -gt 0) {
                        $groups = @($check.Blocking | Group-Object { $_.owner })
                        foreach ($group in $groups) {
                            foreach ($f in $group.Group) { $problems.Add("$($group.Name): [$($f.category)] $($f.message)$(if ($f.fix) { " Fix: $($f.fix)" })") }
                        }
                        $nonRetryable = @($groups | Where-Object { $_.Name -in $NonRetryableOwners })
                        if ($nonRetryable.Count -gt 0) {
                            # The selection or the requirements are wrong: no subagent can fix that.
                            # Stop this branch without re-running anyone, and report everything.
                            $entry.retry_blocked = $true
                            foreach ($group in $groups) {
                                $blocked += [ordered]@{ owner = $group.Name; feedback = @($group.Group | ForEach-Object { "[$($_.category)] $($_.message)" }) }
                            }
                        }
                        else {
                            # Route each blocking finding to the step that owns it (targeted retry).
                            foreach ($group in $groups) {
                                $owner = $group.Name
                                $messages = @($group.Group | ForEach-Object { "[$($_.category)] $($_.message)$(if ($_.fix) { " Fix: $($_.fix)" })" })
                                $target = switch ($owner) {
                                    'quality-validator' { $Step }
                                    'study-planner' { 'plan' }
                                    default { @(Get-ResearchStepNames $state | Where-Object { $state.steps[$_].agent -eq $owner })[0] }
                                }
                                if ($target -ne $Step) { Set-AttemptFailed $state.steps[$target] $messages $Step }
                                $retry += [ordered]@{ step = $target; owner = $owner; feedback = $messages }
                            }
                        }
                    }
                }
            }

            if ($problems.Count -gt 0) {
                if ($kind -ne 'report') { $retry = @([ordered]@{ step = $Step; owner = $entry.agent; feedback = @($problems) }) }
                Set-AttemptFailed $entry $problems
                $attempt = $entry.attempts
                # Saving may invalidate this step (a routed retry reopened one of its inputs).
                Save-State $runDir $state
                foreach ($r in $retry) { $r.attempts_left = Get-AttemptsLeft $state.steps[$r.step] }
                [ordered]@{
                    run_id = $RunId; step = $Step; result = 'failed'; attempt = $attempt; attempts_left = Get-AttemptsLeft $entry; step_status = $entry.status
                    problems = $problems; retry = $retry; blocked = $blocked; workflow_status = $state.workflow_status; failed_steps = $state.failed_steps
                } | ConvertTo-Json -Depth 6
                exit 1
            }

            $now = Get-Now
            $artifactPath = Get-ArtifactPath $runDir $entry
            $entry.status = 'passed'
            $entry.artifact_sha256 = Get-FileHash256 $artifactPath
            $entry.completed_at = $now
            $accepted = Add-AcceptedVersion $runDir $entry $Step
            $result = [ordered]@{ run_id = $RunId; step = $Step; result = 'passed'; attempt = $entry.attempts; version = $accepted.version; artifact = $entry.artifact; artifact_sha256 = $entry.artifact_sha256 }
            if ($accepted.revision) { $result.revision = $accepted.revision }
            if ($Step -eq 'requirements') {
                $lines = Get-Lines $artifactPath
                $line = $lines | Where-Object { $_ -match '^blocking_open_questions:\s*\d+\s*$' } | Select-Object -First 1
                $entry.blocking_open_questions = [int]($line -replace '\D', '')
                $fm = Get-FrontMatter $lines
                $entry.mandatory_topics = @($fm['mandatory_topics'] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
                $entry.time_budget_hours = if (Test-Number "$($fm['time_budget_hours'])") { [double]$fm['time_budget_hours'] } else { $null }
                $result.blocking_open_questions = $entry.blocking_open_questions
                $result.mandatory_topics = $entry.mandatory_topics
                $result.time_budget_hours = $entry.time_budget_hours
            }
            elseif ($kind -eq 'artifact') {
                $entry.source_count = (Get-SectionUrls (Get-Lines $artifactPath) '## Sources').Count
                $result.source_count = $entry.source_count
            }
            elseif ($kind -eq 'plan') {
                $result.planned_hours = $entry.planned_hours
            }
            else {
                $report = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json -AsHashtable
                $advisory = @($report['findings'] | Where-Object { $_ -and $_['severity'] -eq 'advisory' })
                $entry.advisory_findings = $advisory.Count
                $result.advisory_findings = $entry.advisory_findings
                # Advisory findings are never routed. They can be offered to the user as
                # suggested revisions; only the user's explicit request opens one.
                $result.suggested_revisions = @($advisory | ForEach-Object { [ordered]@{ id = $_['id']; owner = $_['owner']; category = $_['category']; message = $_['message'] } })
            }
            $h = [ordered]@{ attempt = $entry.attempts; version = $accepted.version; result = 'passed'; agent_id = $AgentId; at = $now }
            if ($accepted.revision) { $h.revision = $accepted.revision }
            $entry.history += @($h)
            $open = @(Get-List $state['revisions'] | Where-Object { $_.status -eq 'open' })
            Save-State $runDir $state
            # Report the revisions that were in progress, so the coordinator sees one complete.
            if ($open.Count -gt 0) { $result.revisions = @($open | ForEach-Object { [ordered]@{ id = $_.id; step = $_.step; status = $_.status; result_version = $_['result_version'] } }) }
            $result.workflow_status = $state.workflow_status
            $result.next_step = $state.next_step
            $result | ConvertTo-Json -Depth 5
        }

        'fail' {
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            $entry = Get-StepEntry $state
            if ($entry.status -ne 'running') { throw "Step '$Step' is not running (status: $($entry.status))." }
            if ($AgentId) { $entry.agent_id = $AgentId }
            if ($NoRetry) { $entry.retry_blocked = $true }
            Set-AttemptFailed $entry @($(if ($Reason) { $Reason } else { 'unspecified' }))
            Save-State $runDir $state
            [ordered]@{ run_id = $RunId; step = $Step; result = 'failed'; attempt = $entry.attempts; attempts_left = Get-AttemptsLeft $entry; workflow_status = $state.workflow_status } | ConvertTo-Json
        }

        'revise' {
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            $entry = Get-StepEntry $state
            if ($Step -notin $RevisableSteps) { throw "Step '$Step' cannot be revised. Revisable steps: $($RevisableSteps -join ', ')." }
            Assert-Integrity $runDir $state
            $blockers = Get-RevisionBlockers $state $Step
            if ($blockers.Count -gt 0) { throw $blockers[0] }

            if (-not $RequestFile -or -not (Test-Path -LiteralPath $RequestFile -PathType Leaf)) { throw "Revision request file not found: '$RequestFile'." }
            try { $request = Get-Content -LiteralPath $RequestFile -Raw | ConvertFrom-Json -AsHashtable }
            catch { $request = $null }
            $errors = Test-RevisionRequest $runDir $state $request
            if ($errors.Count -gt 0) { [ordered]@{ result = 'invalid'; errors = $errors } | ConvertTo-Json; exit 1 }

            # The request must point at the user's own REVISE PLAN command: the oldest unconsumed
            # ledger entry, a request_changes decision. Its feedback (the user's words) is used.
            $a = $state.steps.approval
            $ledger = Read-Ledger $runDir
            $seq = [int]$a.consumed_through + 1
            $evidenceId = if ($request['evidence'] -is [System.Collections.IDictionary]) { "$($request['evidence']['decision_id'])" } else { '' }
            $structural = if ($ledger.exists) { Get-LedgerProblems $ledger } else { @() }
            $errors = @()
            if (-not $evidenceId) { $errors += "A revision needs the user's REVISE PLAN command, captured as ledger evidence; set 'evidence.decision_id'." }
            elseif (-not $ledger.exists -or $ledger.lines.Count -lt $seq) { $errors += "No unconsumed decision evidence; '$evidenceId' cannot be used." }
            elseif ($structural.Count -gt 0) { $errors += 'The decision ledger is invalid; nothing was consumed.'; $errors += @($structural) }
            else {
                $evidence = $ledger.lines[$seq - 1] | ConvertFrom-Json -AsHashtable
                if ("$($evidence['decision_id'])" -ne $evidenceId) { $errors += "'$evidenceId' is not the oldest unconsumed decision ($($evidence['decision_id']))." }
                elseif ($evidence['decision'] -ne 'request_changes') { $errors += "'$evidenceId' is a '$($evidence['decision'])' decision, not request_changes." }
            }
            if ($errors.Count -gt 0) { [ordered]@{ result = 'invalid'; errors = $errors } | ConvertTo-Json; exit 1 }
            $evidenceReasons = Get-EvidenceReasons $runDir $state $ledger $seq
            $record = Add-ConsumedDecision $a $ledger $seq @($evidenceReasons) 'revise'
            if ($evidenceReasons.Count -gt 0) {
                Save-State $runDir $state
                [ordered]@{ result = 'refused'; consumed = $true; errors = @($evidenceReasons) } | ConvertTo-Json
                exit 1
            }
            $request['feedback'] = "$($evidence['feedback'])"
            $request['evidence'] = [ordered]@{ decision_id = $evidenceId; ledger_seq = $seq; ledger_entry_sha256 = $record.entry_sha256; prompt_sha256 = $evidence['prompt_sha256'] }
            $a.history += @([ordered]@{ result = 'changes_requested'; decision_id = $evidenceId; plan_sha256 = $evidence['plan_sha256']; feedback = $request.feedback; via = 'revise'; at = $record.at })

            $opened = Open-Revision $runDir $state $Step $request $RequestFile
            Save-State $runDir $state
            $after = $opened.after
            [ordered]@{
                run_id          = $RunId
                result          = 'opened'
                revision        = $opened.record.id
                step            = $Step
                owner           = $entry.agent
                artifact        = $entry.artifact
                base_version    = $opened.base.version
                base_snapshot   = $opened.base.snapshot
                request_file    = $opened.record.request_file
                feedback        = $opened.record.feedback
                attempts_left   = Get-AttemptsLeft $entry
                revisions_left  = $MaxRevisions - $opened.used - 1
                invalidated     = @($after | Where-Object { $opened.before[$_] -eq 'passed' -and $state.steps[$_].status -ne 'passed' })
                workflow_status = $state.workflow_status
                current_step    = $state.current_step
            } | ConvertTo-Json -Depth 5
        }

        'decide' {
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            Assert-Integrity $runDir $state
            if (-not $state.steps.Contains('approval')) { throw 'This run has no plan to decide on yet.' }
            Update-Approval $runDir $state
            $a = $state.steps.approval
            $refuse = {
                param([string[]]$Reasons, [bool]$Consumed)
                [ordered]@{ run_id = $RunId; result = 'refused'; consumed = $Consumed; reasons = $Reasons; approval_status = $a.status; workflow_status = $state.workflow_status } | ConvertTo-Json -Depth 5
                exit 1
            }

            $interrupted = @(Get-List $a['ledger_quarantines'] | Where-Object { $_.status -eq 'started' })
            if ($interrupted.Count -gt 0) { & $refuse @("Ledger quarantine $($interrupted[0].id) was interrupted. Run 'state.ps1 quarantine-ledger' again to finish it.") $false }

            # Evidence comes only from the ledger. approval.json and state.json are outputs of
            # this command, never inputs to it.
            $ledger = Read-Ledger $runDir
            if (-not $ledger.exists) {
                & $refuse @("No decision evidence: runs/$RunId/$LedgerPath does not exist. Only a decision the user submits, captured as ledger evidence, can approve, reject, or request changes; approval.json or state.json edits are never evidence.") $false
            }
            $done = [int]$a.consumed_through
            if ($ledger.lines.Count -le $done) { & $refuse @("No unconsumed decision evidence: all $done ledger entries were already consumed.") $false }
            # A malformed or broken chain is never consumed: nothing after the break can be trusted.
            $structural = Get-LedgerProblems $ledger
            if ($structural.Count -gt 0) { & $refuse (@('The decision ledger is invalid; nothing was consumed.') + @($structural)) $false }

            $seq = $done + 1
            $lineSha = $ledger.shas[$seq - 1]
            $entry = $ledger.lines[$seq - 1] | ConvertFrom-Json -AsHashtable
            $decision = "$($entry['decision'])"
            $planSha = Get-InputHash (Join-Path $runDir 'plan.md')
            $evidenceReasons = Get-EvidenceReasons $runDir $state $ledger $seq
            $reasons = @($evidenceReasons)
            $request = $null
            if ($decision -eq 'request_changes' -and $reasons.Count -eq 0) {
                $Step = 'plan'
                $revBlockers = Get-RevisionBlockers $state 'plan'
                foreach ($b in $revBlockers) { $reasons += $b }
                $request = [ordered]@{
                    step              = 'plan'
                    requested_by      = 'user'
                    source            = 'user'
                    advisory_findings = @()
                    reason            = 'The user requested changes when deciding on the validated plan.'
                    feedback          = "$($entry['feedback'])"
                    user_confirmation = "Submitted by the user; captured as ledger entry $($entry['decision_id']) (prompt sha256 $($entry['prompt_sha256']))."
                    evidence          = [ordered]@{ decision_id = $entry['decision_id']; ledger_seq = $seq; ledger_entry_sha256 = $lineSha; prompt_sha256 = $entry['prompt_sha256'] }
                }
                $requestErrors = Test-RevisionRequest $runDir $state $request
                foreach ($e in $requestErrors) { $reasons += $e }
            }

            # The entry is consumed either way, so it can never be applied later.
            $record = Add-ConsumedDecision $a $ledger $seq $reasons 'decide'
            $now = $record.at
            if ($reasons.Count -gt 0) {
                Save-State $runDir $state
                & $refuse $reasons $true
            }

            $result = [ordered]@{ run_id = $RunId; result = $null; decision_id = $record.decision_id; plan_version = $entry['plan_version']; plan_sha256 = $planSha }
            if ($decision -eq 'request_changes') {
                $a.history += @([ordered]@{ result = 'changes_requested'; decision_id = $record.decision_id; plan_sha256 = $planSha; feedback = $request.feedback; at = $now })
                $opened = Open-Revision $runDir $state 'plan' $request $null
                Save-State $runDir $state
                $result.result = 'changes_requested'
                $result.revision = $opened.record.id
                $result.base_snapshot = $opened.base.snapshot
                $result.feedback = $request.feedback
                $result.revisions_left = $MaxRevisions - $opened.used - 1
            }
            else {
                # A new decision replaces whatever was recorded before (e.g. reject after approve).
                if ($a.status -eq 'approved') { Reset-Approval $runDir $a 'superseded' @("superseded by $($record.decision_id) ($decision)") }
                $status = if ($decision -eq 'approve') { 'approved' } else { 'rejected' }
                $pvSha = $state.steps.'plan-validation'.artifact_sha256
                $doc = [ordered]@{
                    schema                 = 1
                    run_id                 = $RunId
                    decision               = $status
                    decision_id            = $record.decision_id
                    ledger_seq             = $seq
                    ledger_entry_sha256    = $lineSha
                    plan_sha256            = $planSha
                    plan_version           = $state.steps.plan.version
                    plan_validation_sha256 = $pvSha
                    decided_at             = $now
                    recorded_by            = 'state.ps1 decide'
                }
                $path = Get-ArtifactPath $runDir $a
                Write-JsonAtomic $path $doc
                $a.status = $status
                $a.decision = $status
                $a.decision_id = $record.decision_id
                $a.ledger_seq = $seq
                $a.ledger_entry_sha256 = $lineSha
                $a.plan_sha256 = $planSha
                $a.plan_version = $state.steps.plan.version
                $a.plan_validation_sha256 = $pvSha
                $a.artifact_sha256 = Get-FileHash256 $path
                $a.completed_at = $now
                $a.attempts = [int]$a.attempts + 1
                $accepted = Add-AcceptedVersion $runDir $a 'approval'
                $a.history += @([ordered]@{ result = $status; decision_id = $record.decision_id; version = $accepted.version; plan_sha256 = $planSha; at = $now })
                Save-State $runDir $state
                $result.result = $status
            }
            $result.remaining_unconsumed = $ledger.lines.Count - $seq
            $result.approval_status = $state.steps.approval.status
            $result.workflow_status = $state.workflow_status
            $result.next_step = $state.next_step
            $result | ConvertTo-Json -Depth 5
        }

        'quarantine-ledger' {
            # Removes evidence only: it never writes a ledger entry, consumes one, or changes the
            # approval status. Two files change (the quarantine file, then the ledger), so the
            # intent and every expected hash are recorded first; running the command again
            # resumes an interrupted quarantine by comparing hashes on disk.
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            if (-not $state.steps.Contains('approval')) { throw 'This run has no decision ledger.' }
            $a = $state.steps.approval
            # Consumed entries are history; a damaged history is never quarantined or rewritten.
            $violations = Get-IntegrityViolations $runDir $state
            $damaged = @($violations | Where-Object { $_.step -eq 'approval-ledger' })
            if ($damaged.Count -gt 0) {
                Save-State $runDir $state
                throw "Integrity violation: $(Format-Violation $damaged[0])"
            }
            $ledgerFile = Join-Path $runDir $LedgerPath
            $ledger = Read-Ledger $runDir
            $current = Get-InputHash $ledgerFile
            $record = @(Get-List $a['ledger_quarantines'] | Where-Object { $_.status -eq 'started' }) | Select-Object -First 1

            if (-not $record) {
                $first = if ($ledger.exists) { Get-FirstBadLedgerLine $ledger } else { 0 }
                if ($first -eq 0) {
                    [ordered]@{ run_id = $RunId; result = 'refused'; reasons = @($(if ($ledger.exists) { 'The decision ledger is structurally valid; there is nothing to quarantine.' } else { 'There is no decision ledger.' })) } | ConvertTo-Json
                    exit 1
                }
                if ($first -le [int]$a.consumed_through) { throw "Line $first is malformed but was already consumed; consumed history is never quarantined." }
                $kept = @($ledger.lines | Select-Object -First ($first - 1))
                $moved = @($ledger.lines | Select-Object -Skip ($first - 1))
                $problems = Get-LedgerProblems $ledger
                $id = 'q-{0:000}' -f (@(Get-List $a['ledger_quarantines']).Count + 1)
                $record = [ordered]@{
                    id                 = $id
                    status             = 'started'
                    reason             = $(if ($Reason) { $Reason } else { 'malformed unconsumed decision evidence' })
                    problems           = @($problems)
                    first_line         = $first
                    last_line          = $ledger.lines.Count
                    line_count         = $moved.Count
                    consumed_through   = [int]$a.consumed_through
                    original_sha256    = $current
                    kept_sha256        = Get-StringHash256 (Get-LedgerText $kept)
                    quarantined_sha256 = Get-StringHash256 (Get-LedgerText $moved)
                    quarantine_file    = "runs/$RunId/approval/quarantine/$id.jsonl"
                    started_at         = Get-Now
                    completed_at       = $null
                }
                $a.ledger_quarantines = @(Get-List $a['ledger_quarantines']) + @($record)
                Save-State $runDir $state
            }
            elseif ($current -eq $record.original_sha256) {
                $kept = @($ledger.lines | Select-Object -First ($record.first_line - 1))
                $moved = @($ledger.lines | Select-Object -Skip ($record.first_line - 1))
            }
            elseif ($current -ne $record.kept_sha256) {
                throw "Quarantine $($record.id) cannot be resumed: the ledger is neither the original ($($record.original_sha256.Substring(0, 12))) nor the expected result ($($record.kept_sha256.Substring(0, 12)))."
            }

            if ($current -eq $record.original_sha256 -and
                ((Get-StringHash256 (Get-LedgerText $kept)) -ne $record.kept_sha256 -or (Get-StringHash256 (Get-LedgerText $moved)) -ne $record.quarantined_sha256)) {
                throw "Quarantine $($record.id): the split of the ledger does not match the recorded hashes; nothing was changed."
            }
            # 1. The quarantine file. An existing file with other content is never overwritten.
            $qPath = Join-Path $runDir $record.quarantine_file.Substring("runs/$RunId/".Length)
            $qSha = Get-InputHash $qPath
            if ($qSha -and $qSha -ne $record.quarantined_sha256) { throw "Quarantine file $($record.quarantine_file) exists with other content; it is never overwritten." }
            if (-not $qSha) {
                if ($current -ne $record.original_sha256) { throw "Quarantine $($record.id) cannot be resumed: the ledger was already rewritten but $($record.quarantine_file) is missing." }
                New-Item -ItemType Directory -Path (Split-Path $qPath) -Force | Out-Null
                Write-TextAtomic $qPath (Get-LedgerText $moved)
                if ((Get-InputHash $qPath) -ne $record.quarantined_sha256) { throw "Quarantine file $($record.quarantine_file) does not have the expected content." }
            }
            # 2. The ledger keeps the lines before the first malformed one.
            if ($current -eq $record.original_sha256) {
                Write-TextAtomic $ledgerFile (Get-LedgerText $kept)
                if ((Get-InputHash $ledgerFile) -ne $record.kept_sha256) { throw 'The rewritten ledger does not have the expected content.' }
            }
            # 3. Done.
            $record.status = 'completed'
            $record.completed_at = Get-Now
            $a.history += @([ordered]@{
                    result = 'ledger_quarantined'; quarantine = $record.id; reason = $record.reason; first_line = $record.first_line; line_count = $record.line_count
                    original_sha256 = $record.original_sha256; kept_sha256 = $record.kept_sha256; quarantined_sha256 = $record.quarantined_sha256; at = $record.completed_at
                })
            Save-State $runDir $state
            [ordered]@{
                run_id           = $RunId
                result           = 'quarantined'
                quarantine       = $record.id
                quarantine_file  = $record.quarantine_file
                first_line       = $record.first_line
                line_count       = $record.line_count
                kept_lines       = $record.first_line - 1
                consumed_through = [int]$a.consumed_through
                problems         = $record.problems
                approval_status  = $a.status
                workflow_status  = $state.workflow_status
            } | ConvertTo-Json -Depth 5
        }

        'ledger-status' {
            $runDir = Get-RunDir
            $state = Read-State $runDir
            $ledger = Read-Ledger $runDir
            $a = $state.steps['approval']
            $problems = if ($ledger.exists) { Get-LedgerProblems $ledger } else { @() }
            $blockers = if ($a) { Get-ApprovalBlockers $state } else { @('this run has no plan to decide on yet') }
            $violations = Get-IntegrityViolations $runDir $state
            # Runs before research selection (and old schema-1 runs) have no plan step.
            $plan = $state.steps['plan']
            [ordered]@{
                run_id                = $RunId
                approval_status       = $(if ($a) { $a.status } else { $null })
                decidable             = [bool]($a -and $blockers.Count -eq 0 -and $a.status -ne 'rejected' -and $violations.Count -eq 0)
                blockers              = @(@($blockers) + @($violations | ForEach-Object { "integrity violation: $($_.step)" }))
                plan_sha256           = Get-InputHash (Join-Path $runDir 'plan.md')
                accepted_plan_sha256  = $(if ($plan) { $plan['artifact_sha256'] } else { $null })
                plan_version          = $(if ($plan) { $plan['version'] } else { $null })
                ledger_exists         = $ledger.exists
                ledger_valid          = ($problems.Count -eq 0)
                ledger_problems       = @($problems)
                line_count            = $ledger.lines.Count
                last_line_sha256      = $(if ($ledger.lines.Count) { $ledger.shas[-1] } else { $ZeroSha256 })
                consumed_through      = $(if ($a) { [int]$a.consumed_through } else { 0 })
                quarantine_in_progress = [bool]@(Get-List $(if ($a) { $a['ledger_quarantines'] }) | Where-Object { $_.status -eq 'started' }).Count
            } | ConvertTo-Json -Depth 5
        }

        'verify' {
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            $violations = Get-IntegrityViolations $runDir $state
            Save-State $runDir $state
            [ordered]@{
                run_id          = $RunId
                result          = $(if ($violations.Count) { 'violated' } else { 'ok' })
                violations      = @($violations | ForEach-Object { [ordered]@{ step = $_.step; artifact = $_.artifact; message = (Format-Violation $_) } })
                workflow_status = $state.workflow_status
                next_step       = $state.next_step
            } | ConvertTo-Json -Depth 5
            if ($violations.Count) { exit 1 }
        }

        'resolve' {
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            if ($Step -eq 'approval-ledger') { throw 'Consumed ledger entries cannot be restored or discarded by a command: put the consumed lines back exactly as they were, by hand.' }
            if ($Step -eq 'render-output') { throw 'An unauthorized guide.html is never accepted or deleted by a command: move or delete it yourself.' }
            $entry = Get-StepEntry $state
            if (-not $Resolution) { throw 'Missing -Resolution (restore or discard).' }
            $v = @(Update-Integrity $runDir $state | Where-Object { $_.step -eq $Step })
            if ($v.Count -eq 0) { throw "Step '$Step' has no integrity violation to resolve." }
            $path = Get-ArtifactPath $runDir $entry
            $now = Get-Now
            # Keep the modified file for audit; it is never used as an input.
            $kept = $null
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                New-Item -ItemType Directory -Path (Join-Path $runDir 'versions') -Force | Out-Null
                $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfff')
                $kept = "versions/$Step-modified-$stamp$([System.IO.Path]::GetExtension($path))"
                Copy-Item -LiteralPath $path -Destination (Join-Path $runDir $kept) -Force
            }
            $integrityEvent = [ordered]@{ step = $Step; resolution = $Resolution; expected_sha256 = $v[0].expected_sha256; found_sha256 = $v[0].actual_sha256; modified_copy = $(if ($kept) { "runs/$RunId/$kept" } else { $null }); at = $now }
            switch ($Resolution) {
                'restore' {
                    $accepted = @(Get-List $entry['accepted_versions'] | Where-Object { $_.sha256 -eq $entry.artifact_sha256 })
                    $snapshot = if ($accepted.Count) { Join-Path $runDir $accepted[-1].snapshot.Substring("runs/$RunId/".Length) } else { $null }
                    if (-not $snapshot -or -not (Test-Path -LiteralPath $snapshot -PathType Leaf) -or (Get-FileHash256 $snapshot) -ne $entry.artifact_sha256) {
                        throw "No intact snapshot of the accepted '$Step' artifact exists (runs created before versions were recorded have none). Revert the file by hand, or use -Resolution discard."
                    }
                    $tmp = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
                    try { Copy-Item -LiteralPath $snapshot -Destination $tmp -Force; [System.IO.File]::Move($tmp, $path, $true) }
                    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
                    $integrityEvent.restored_version = $accepted[-1].version
                }
                'discard' {
                    if ($Step -eq 'requirements') { throw 'requirements.md can only be restored; re-running requirements is not supported.' }
                    # The owner regenerates the artifact on a fresh budget, like an invalidation.
                    Reset-Invalidated $entry @("integrity: manual modification discarded ($($integrityEvent.found_sha256))")
                    $entry.history[-1].result = 'discarded'
                }
            }
            $state.integrity.events = @(Get-List $state.integrity['events']) + @($integrityEvent)
            Save-State $runDir $state
            [ordered]@{
                run_id          = $RunId
                step            = $Step
                result          = $Resolution
                modified_copy   = $integrityEvent.modified_copy
                step_status     = $entry.status
                integrity       = $state.integrity.status
                workflow_status = $state.workflow_status
                current_step    = $state.current_step
                next_step       = $state.next_step
            } | ConvertTo-Json -Depth 5
        }

        'show' {
            $runDir = Get-RunDir
            Get-Content -LiteralPath (Join-Path $runDir 'state.json') -Raw
        }
    }
}
finally {
    if ($lock) { $lock.Dispose() }
}
