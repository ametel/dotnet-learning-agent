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
      show      Print state.json.

    On every save, downstream steps whose input steps are no longer passed, or whose input
    files changed, are reset to pending with a fresh attempt budget (CLAUDE.md §5.2).

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
    [ValidateSet('init', 'select', 'start', 'complete', 'fail', 'show')]
    [string]$Action,

    [string]$RunId,
    [string]$Step,
    [string]$Label = 'run',
    [string]$AgentId,
    [string]$Reason,
    [string]$SelectionFile,
    [switch]$NoRetry,
    # Overridable for testing; defaults to <repo>/runs.
    [string]$RunsRoot = (Join-Path $PSScriptRoot '..' 'runs')
)

$ErrorActionPreference = 'Stop'
$MaxAttempts = 3
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

function Write-JsonAtomic([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 10
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmp, $json + "`n", [System.Text.UTF8Encoding]::new($false))
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
    Get-Content -LiteralPath (Join-Path $RunDir 'state.json') -Raw | ConvertFrom-Json @params
}

function Save-State([string]$RunDir, $State) {
    Update-Invalidation $RunDir $State
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
    $urls = foreach ($line in $Lines) {
        foreach ($m in [regex]::Matches($line, 'https?://[^\s<>()\[\]"''`|]+')) { $m.Value.TrimEnd('.', ',', ';', ':') }
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

# Reasons a downstream step's inputs are no longer valid (empty = fresh).
function Get-StaleReasons([string]$RunDir, $State, [string]$Name) {
    $entry = $State.steps[$Name]
    $reasons = @(foreach ($p in Get-Prerequisites $State $Name) {
            if ($State.steps[$p].status -ne 'passed') { "input step '$p' is $($State.steps[$p].status)" }
        })
    if ($entry.inputs_sha256) {
        $current = Get-DownstreamInputs $RunDir $State $Name
        foreach ($k in $current.Keys) {
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

function Update-Invalidation([string]$RunDir, $State) {
    if (-not $State.steps.Contains('coverage')) { return }
    foreach ($name in $DownstreamSteps.Keys) {
        $entry = $State.steps[$name]
        if ($entry.status -notin 'passed', 'failed' -or -not $entry.inputs_sha256) { continue }
        $reasons = Get-StaleReasons $RunDir $State $name
        if ($reasons.Count -gt 0) { Reset-Invalidated $entry $reasons }
    }
}

# Derive workflow_status / current_step / next_step from the steps, so they can't drift.
function Update-Workflow($State) {
    $steps = $State.steps
    $req = $steps.requirements
    $research = @(Get-ResearchStepNames $State | ForEach-Object { $steps[$_] })
    $State.failed_steps = @($steps.Keys | Where-Object { Test-Exhausted $steps[$_] })
    $State.next_step = $null
    $State.current_step = $null

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
    $State.workflow_status = 'paused'
    $State.next_step = 'approval (not implemented yet)'
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
    $h = [ordered]@{ attempt = $Entry.attempts; result = 'failed'; reasons = $Reasons; at = $now }
    if ($Gate) { $h.gate = $Gate }
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
            # Apply pending invalidations first (an input may have been edited since the last
            # save), so a stale passed step can be re-run instead of reporting "already passed".
            Update-Invalidation $runDir $state
            $entry = Get-StepEntry $state
            if ($entry.status -eq 'passed') { throw "Step '$Step' already passed." }
            if ($entry.status -eq 'running') { throw "Step '$Step' is already running (attempt $($entry.attempts)). Complete or fail it first." }

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
            if ($AgentId) { $entry.agent_id = $AgentId }
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
            $result = [ordered]@{ run_id = $RunId; step = $Step; result = 'passed'; attempt = $entry.attempts; artifact = $entry.artifact; artifact_sha256 = $entry.artifact_sha256 }
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
                $entry.advisory_findings = @($report['findings'] | Where-Object { $_ -and $_['severity'] -eq 'advisory' }).Count
                $result.advisory_findings = $entry.advisory_findings
            }
            $entry.history += @([ordered]@{ attempt = $entry.attempts; result = 'passed'; agent_id = $AgentId; at = $now })
            Save-State $runDir $state
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

        'show' {
            $runDir = Get-RunDir
            Get-Content -LiteralPath (Join-Path $runDir 'state.json') -Raw
        }
    }
}
finally {
    if ($lock) { $lock.Dispose() }
}
