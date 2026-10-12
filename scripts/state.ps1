#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic workflow-state helper for dotnet-learning-agent runs.

.DESCRIPTION
    The coordinator (/prepare-interview) is the only caller. Subagents never run this.
    Every read-modify-write of state.json holds a per-run lock (state.lock), so parallel
    calls are safe, and every write is atomic (temp file in the same directory, then rename).

    Actions:
      init      Create a new run directory and state.json. Prints run paths as JSON.
      select    Record the research-agent selection from -SelectionFile and create one
                research step per selected agent.
      start     Mark a step as running and increment its attempt count (max 3).
      complete  Verify the step's artifact, then mark the step passed or failed.
      fail      Mark the current attempt of a step as failed with a reason.
                -NoRetry marks the failure as not worth retrying (e.g. tools unavailable).
      show      Print state.json.

.EXAMPLE
    pwsh -NoProfile -File scripts/state.ps1 init -Label senior-backend
    pwsh -NoProfile -File scripts/state.ps1 start -RunId <id> -Step requirements
    pwsh -NoProfile -File scripts/state.ps1 complete -RunId <id> -Step requirements -AgentId <agent-id>
    pwsh -NoProfile -File scripts/state.ps1 select -RunId <id> -SelectionFile runs/<id>/research-selection.json
    pwsh -NoProfile -File scripts/state.ps1 start -RunId <id> -Step research-data
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

function Test-Exhausted($Entry) {
    $Entry.status -eq 'failed' -and ($Entry.attempts -ge $MaxAttempts -or $Entry['retry_blocked'])
}

# Derive workflow_status / current_step / next_step from the steps, so they can't drift.
function Update-Workflow($State) {
    $steps = $State.steps
    $req = $steps.requirements
    $research = @($steps.Keys | Where-Object { $_ -like 'research-*' } | ForEach-Object { $steps[$_] })
    $State.failed_steps = @($steps.Keys | Where-Object { Test-Exhausted $steps[$_] })
    $State.next_step = $null

    if ($req.status -ne 'passed') {
        $State.workflow_status = if (Test-Exhausted $req) { 'failed' } else { 'in_progress' }
        $State.current_step = 'requirements'
    }
    elseif ($research.Count -eq 0) {
        $State.workflow_status = 'paused'
        $State.current_step = $null
        $State.next_step = 'research-selection'
    }
    elseif (@($research | Where-Object { $_.status -ne 'passed' -and -not (Test-Exhausted $_) }).Count -gt 0) {
        # At least one research step is pending, running, or retryable.
        $State.workflow_status = 'in_progress'
        $State.current_step = 'research'
    }
    elseif ($State.failed_steps.Count -gt 0) {
        $State.workflow_status = 'failed'
        $State.current_step = $null
    }
    else {
        $State.workflow_status = 'paused'
        $State.current_step = $null
        $State.next_step = 'synthesis (not implemented yet)'
    }
}

# Distinct URLs in the lines between $Heading and the next "## " heading.
function Get-SectionUrls([string[]]$Lines, [string]$Heading) {
    $inSection = $false
    $urls = foreach ($line in $Lines) {
        if ($line -eq $Heading) { $inSection = $true; continue }
        if ($inSection -and $line -match '^## ') { break }
        if ($inSection) {
            foreach ($m in [regex]::Matches($line, 'https?://[^\s<>()\[\]"'']+')) { $m.Value.TrimEnd('.', ',', ';', ':') }
        }
    }
    @($urls | Select-Object -Unique)
}

# Returns the list of gate problems for the step's artifact (empty = passed).
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

function Set-AttemptFailed($Entry, [string[]]$Reasons) {
    $now = Get-Now
    $Entry.status = 'failed'
    $Entry.completed_at = $now
    $Entry.history += @([ordered]@{ attempt = $Entry.attempts; result = 'failed'; reasons = $Reasons; at = $now })
}

function Get-AttemptsLeft($Entry) { if ($Entry['retry_blocked']) { 0 } else { $MaxAttempts - $Entry.attempts } }

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
                schema_version  = 1
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
            $seenTopics = @{}
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
                    $key = $t.ToLowerInvariant()
                    if ($seenTopics.ContainsKey($key)) { $errors.Add("Topic '$t' is assigned to more than one agent.") }
                    $seenTopics[$key] = $true
                }
            }
            foreach ($agent in $byAgent.Keys) {
                if (-not $seenAgents.ContainsKey($agent)) { $errors.Add("Agent '$agent' must appear in 'selected' or 'not_selected' (with a reason).") }
            }
            if ($errors.Count -gt 0) { [ordered]@{ result = 'invalid'; errors = $errors } | ConvertTo-Json; exit 1 }

            $now = Get-Now
            $state.research = [ordered]@{
                selected_at       = $now
                selection_file    = (Resolve-Path -LiteralPath $SelectionFile -Relative).Replace('\', '/') -replace '^\./', ''
                selection_sha256  = Get-FileHash256 $SelectionFile
                selected_agents   = @()
                not_selected      = @($notSelected | ForEach-Object { [ordered]@{ agent = $_['agent']; reason = $_['reason'] } })
            }
            New-Item -ItemType Directory -Path (Join-Path $runDir 'research') -Force | Out-Null
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
            Save-State $runDir $state
            [ordered]@{
                run_id   = $RunId
                result   = 'selected'
                steps    = @($state.research.selected_agents | ForEach-Object { [ordered]@{ step = $_.step; agent = $_.agent; artifact = $_.artifact; topics = $_.topics } })
                skipped  = @($state.research.not_selected | ForEach-Object { $_.agent })
            } | ConvertTo-Json -Depth 5
        }

        'start' {
            $runDir = Get-RunDir
            $lock = Enter-StateLock $runDir
            $state = Read-State $runDir
            $entry = Get-StepEntry $state
            if ($entry.status -eq 'passed') { throw "Step '$Step' already passed." }
            if ($entry.status -eq 'running') { throw "Step '$Step' is already running (attempt $($entry.attempts)). Complete or fail it first." }
            if ($entry['retry_blocked']) { throw "Step '$Step' failed with a non-retryable error." }
            if ($entry.attempts -ge $MaxAttempts) { throw "Step '$Step' has used all $MaxAttempts attempts." }

            $inputPath = Join-Path $runDir 'confirmed-input.md'
            if (-not (Test-Path -LiteralPath $inputPath)) { throw "Missing confirmed input: runs/$RunId/confirmed-input.md" }

            if ($Step -eq 'requirements') {
                $entry.input_sha256 = Get-FileHash256 $inputPath
            }
            else {
                $req = $state.steps.requirements
                if ($req.status -ne 'passed') { throw 'Requirements step must pass before research starts.' }
                $reqHash = Get-FileHash256 (Get-ArtifactPath $runDir $req)
                if ($reqHash -ne $req.artifact_sha256) { throw 'requirements.md changed after it passed (stale). Re-run the requirements step first.' }
                $inputHash = Get-FileHash256 $inputPath
                if ($inputHash -ne $req.input_sha256) { throw 'confirmed-input.md changed after requirements were built from it (stale). Re-run the requirements step first.' }
                $entry.inputs_sha256 = [ordered]@{
                    confirmed_input = $inputHash
                    requirements    = $reqHash
                    assignment      = Get-StringHash256 (@($entry.topics) -join "`n")
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

            $problems = Test-Artifact $runDir $state $entry
            if ($AgentId) { $entry.agent_id = $AgentId }
            if ($problems.Count -gt 0) {
                Set-AttemptFailed $entry $problems
                Save-State $runDir $state
                [ordered]@{ run_id = $RunId; step = $Step; result = 'failed'; attempt = $entry.attempts; attempts_left = Get-AttemptsLeft $entry; problems = $problems; workflow_status = $state.workflow_status } | ConvertTo-Json
                exit 1
            }

            $now = Get-Now
            $artifactPath = Get-ArtifactPath $runDir $entry
            $entry.status = 'passed'
            $entry.artifact_sha256 = Get-FileHash256 $artifactPath
            $entry.completed_at = $now
            $result = [ordered]@{ run_id = $RunId; step = $Step; result = 'passed'; attempt = $entry.attempts; artifact = $entry.artifact; artifact_sha256 = $entry.artifact_sha256 }
            if ($Step -eq 'requirements') {
                $line = Get-Content -LiteralPath $artifactPath -Encoding utf8 | Where-Object { $_ -match '^blocking_open_questions:\s*\d+\s*$' } | Select-Object -First 1
                $entry.blocking_open_questions = [int]($line -replace '\D', '')
                $result.blocking_open_questions = $entry.blocking_open_questions
            }
            else {
                $entry.source_count = (Get-SectionUrls @(Get-Content -LiteralPath $artifactPath -Encoding utf8 | ForEach-Object { $_.TrimEnd() }) '## Sources').Count
                $result.source_count = $entry.source_count
            }
            $entry.history += @([ordered]@{ attempt = $entry.attempts; result = 'passed'; agent_id = $AgentId; at = $now })
            Save-State $runDir $state
            $result.workflow_status = $state.workflow_status
            $result | ConvertTo-Json
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
