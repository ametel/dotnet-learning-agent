#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic workflow-state helper for dotnet-learning-agent runs.

.DESCRIPTION
    The coordinator (/prepare-interview) is the only caller. Subagents never run this.
    All writes to state.json are atomic (temp file in the same directory, then rename).

    Actions:
      init      Create a new run directory and state.json. Prints run paths as JSON.
      start     Mark a step as running and increment its attempt count (max 3).
      complete  Verify the step's artifact, then mark the step passed or failed.
      fail      Mark the current attempt of a step as failed with a reason.
      show      Print state.json.

.EXAMPLE
    pwsh -NoProfile -File scripts/state.ps1 init -Label senior-backend
    pwsh -NoProfile -File scripts/state.ps1 start -RunId <id> -Step requirements
    pwsh -NoProfile -File scripts/state.ps1 complete -RunId <id> -Step requirements -AgentId <agent-id>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('init', 'start', 'complete', 'fail', 'show')]
    [string]$Action,

    [string]$RunId,
    [string]$Step,
    [string]$Label = 'run',
    [string]$AgentId,
    [string]$Reason,
    # Overridable for testing; defaults to <repo>/runs.
    [string]$RunsRoot = (Join-Path $PSScriptRoot '..' 'runs')
)

$ErrorActionPreference = 'Stop'
$MaxAttempts = 3

# Section headings each step's artifact must contain (structure gate).
$RequiredHeadings = @{
    requirements = @(
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
}

# Integer front-matter fields each step's artifact must declare.
$RequiredFrontMatter = @{
    requirements = @('blocking_open_questions')
}

function Get-Now { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Get-FileHash256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Write-JsonAtomic([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 10
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    [System.IO.File]::WriteAllText($tmp, $json + "`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tmp, $Path, $true)
}

function Get-RunDir {
    if (-not $RunId) { throw 'Missing -RunId.' }
    if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid run id '$RunId'." }
    $dir = Join-Path $RunsRoot $RunId
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'state.json'))) { throw "No state.json for run '$RunId' under '$RunsRoot'." }
    return $dir
}

function Read-State([string]$RunDir) {
    $params = @{ AsHashtable = $true }
    # Keep ISO timestamps as strings instead of converting them to DateTime (PowerShell 7.5+).
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $params.DateKind = 'String' }
    Get-Content -LiteralPath (Join-Path $RunDir 'state.json') -Raw | ConvertFrom-Json @params
}

function Save-State([string]$RunDir, $State) {
    $State.updated_at = Get-Now
    Write-JsonAtomic (Join-Path $RunDir 'state.json') $State
}

function Get-StepEntry($State) {
    if (-not $Step) { throw 'Missing -Step.' }
    if (-not $State.steps.ContainsKey($Step)) { throw "Unknown step '$Step'." }
    return $State.steps[$Step]
}

function Set-AttemptFailed($State, $Entry, [string[]]$Reasons) {
    $now = Get-Now
    $Entry.status = 'failed'
    $Entry.completed_at = $now
    $Entry.history += @([ordered]@{ attempt = $Entry.attempts; result = 'failed'; reasons = $Reasons; at = $now })
    if ($Entry.attempts -ge $MaxAttempts) {
        $State.workflow_status = 'failed'
        $State.current_step = $Step
    }
}

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
        Write-JsonAtomic (Join-Path $runDir 'state.json') $state
        [ordered]@{
            run_id            = $RunId
            run_dir           = "runs/$RunId"
            state_path        = "runs/$RunId/state.json"
            confirmed_input   = "runs/$RunId/confirmed-input.md"
            requirements_path = "runs/$RunId/requirements.md"
        } | ConvertTo-Json
    }

    'start' {
        $runDir = Get-RunDir
        $state = Read-State $runDir
        $entry = Get-StepEntry $state
        if ($state.workflow_status -eq 'failed') { throw "Run '$RunId' has failed; start a new run." }
        if ($entry.status -eq 'passed') { throw "Step '$Step' already passed." }
        if ($entry.status -eq 'running') { throw "Step '$Step' is already running (attempt $($entry.attempts)). Complete or fail it first." }
        if ($entry.attempts -ge $MaxAttempts) { throw "Step '$Step' has used all $MaxAttempts attempts." }

        $inputPath = Join-Path $runDir 'confirmed-input.md'
        if (-not (Test-Path -LiteralPath $inputPath)) { throw "Missing confirmed input: runs/$RunId/confirmed-input.md" }

        $entry.attempts += 1
        $entry.status = 'running'
        $entry.input_sha256 = Get-FileHash256 $inputPath
        $entry.started_at = Get-Now
        $entry.completed_at = $null
        $state.current_step = $Step
        Save-State $runDir $state
        [ordered]@{ run_id = $RunId; step = $Step; attempt = $entry.attempts; max_attempts = $MaxAttempts } | ConvertTo-Json
    }

    'complete' {
        $runDir = Get-RunDir
        $state = Read-State $runDir
        $entry = Get-StepEntry $state
        if ($entry.status -ne 'running') { throw "Step '$Step' is not running (status: $($entry.status))." }

        $artifactPath = Join-Path $runDir (Split-Path $entry.artifact -Leaf)
        $problems = @()
        $content = $null
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            $problems += "Artifact not found: $($entry.artifact)"
        }
        else {
            try { $content = Get-Content -LiteralPath $artifactPath -Raw -Encoding utf8 }
            catch { $problems += "Artifact not readable: $($_.Exception.Message)" }
            if ($null -ne $content -and -not $content.Trim()) { $problems += 'Artifact is empty.' }
        }
        if ($content) {
            $lines = $content -split "`r?`n" | ForEach-Object { $_.TrimEnd() }
            foreach ($h in $RequiredHeadings[$Step]) {
                if ($lines -notcontains $h) { $problems += "Missing heading: '$h'" }
            }
            foreach ($key in $RequiredFrontMatter[$Step]) {
                if (-not ($lines -match "^${key}:\s*\d+$")) { $problems += "Missing or non-numeric front-matter field: '$key'" }
            }
        }

        $now = Get-Now
        if ($AgentId) { $entry.agent_id = $AgentId }
        if ($problems.Count -gt 0) {
            Set-AttemptFailed $state $entry $problems
            Save-State $runDir $state
            [ordered]@{ run_id = $RunId; step = $Step; result = 'failed'; attempt = $entry.attempts; attempts_left = $MaxAttempts - $entry.attempts; problems = $problems } | ConvertTo-Json
            exit 1
        }

        $entry.status = 'passed'
        $entry.artifact_sha256 = Get-FileHash256 $artifactPath
        $entry.completed_at = $now
        $blocking = ($lines | Where-Object { $_ -match '^blocking_open_questions:\s*(\d+)$' } | Select-Object -First 1) -replace '\D', ''
        if ($blocking -ne '') { $entry.blocking_open_questions = [int]$blocking }
        $entry.history += @([ordered]@{ attempt = $entry.attempts; result = 'passed'; agent_id = $AgentId; at = $now })
        # Phase 2A ends after requirements; later phases add more steps.
        $state.workflow_status = 'paused'
        $state.current_step = $null
        $state.next_step = 'research (not implemented yet)'
        Save-State $runDir $state
        [ordered]@{ run_id = $RunId; step = $Step; result = 'passed'; attempt = $entry.attempts; artifact = $entry.artifact; artifact_sha256 = $entry.artifact_sha256; blocking_open_questions = $entry.blocking_open_questions } | ConvertTo-Json
    }

    'fail' {
        $runDir = Get-RunDir
        $state = Read-State $runDir
        $entry = Get-StepEntry $state
        if ($entry.status -ne 'running') { throw "Step '$Step' is not running (status: $($entry.status))." }
        if ($AgentId) { $entry.agent_id = $AgentId }
        Set-AttemptFailed $state $entry @($(if ($Reason) { $Reason } else { 'unspecified' }))
        Save-State $runDir $state
        [ordered]@{ run_id = $RunId; step = $Step; result = 'failed'; attempt = $entry.attempts; attempts_left = $MaxAttempts - $entry.attempts } | ConvertTo-Json
    }

    'show' {
        $runDir = Get-RunDir
        Get-Content -LiteralPath (Join-Path $runDir 'state.json') -Raw
    }
}
