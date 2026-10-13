#Requires -Version 7.0
<#
.SYNOPSIS
    Prepares an existing run to continue after a Claude Code session ended (CLAUDE.md §7).

.DESCRIPTION
    Uses only the existing state machine; it stores nothing new and decides nothing itself:
      1. `state.ps1 verify`: refuses on any integrity violation (the run must be resolved
         first), and re-applies the existing invalidation, approval, and workflow rules.
      2. Every step still `running` was interrupted when the session ended. Its attempt is
         recorded as failed with `state.ps1 fail` (reason "interrupted"): the existing
         transition, counted against the same 3 attempts, never treated as a success.
      3. `state.ps1 verify` again, then prints the next action for the coordinator, derived
         from the recorded workflow_status and current_step. Passed steps are listed as
         skipped; only unfinished steps are named.
    Approval is never decided here: an awaiting run waits for the user, and only decision
    evidence the user already submitted is handed to `state.ps1 decide`.

.EXAMPLE
    pwsh -NoProfile -File scripts/resume-run.ps1 -RunId <id>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [string]$RunsRoot = (Join-Path $PSScriptRoot '..' 'runs'),
    [string]$StateScript = (Join-Path $PSScriptRoot 'state.ps1')
)
$ErrorActionPreference = 'Stop'

function Invoke-State([string[]]$Arguments) {
    $output = & pwsh -NoProfile -NonInteractive -File $StateScript @Arguments -RunId $RunId -RunsRoot $RunsRoot 2>&1
    $code = $LASTEXITCODE
    $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = (($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n") -replace '\x1b\[[0-9;]*m', ''
    $json = $null
    if ($stdout.Trim()) { try { $json = $stdout | ConvertFrom-Json -AsHashtable } catch { } }
    [pscustomobject]@{ ExitCode = $code; Json = $json; Stdout = $stdout; Stderr = $stderr }
}

function Stop-Refused([string]$Reason, $Details = $null) {
    $out = [ordered]@{ run_id = $RunId; result = 'refused'; reason = $Reason }
    if ($Details) { $out.details = $Details }
    $out | ConvertTo-Json -Depth 6
    exit 1
}

# Integrity first; verify also refreshes invalidations and the workflow status.
function Assert-Verified {
    $v = Invoke-State @('verify')
    if ($v.ExitCode -ne 0) {
        if ($v.Json -and $v.Json.violations) {
            Stop-Refused 'Integrity violation: resolve it before resuming (CLAUDE.md §6.4).' @($v.Json.violations | ForEach-Object { $_.message })
        }
        Stop-Refused "The run could not be verified: $(("$($v.Stderr) $($v.Stdout)").Trim())"
    }
}

function Read-RunState {
    $params = @{ AsHashtable = $true }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $params.DateKind = 'String' }
    Get-Content -LiteralPath (Join-Path $RunsRoot $RunId 'state.json') -Raw | ConvertFrom-Json @params
}

if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Stop-Refused "Invalid run id '$RunId'." }
if (-not (Test-Path -LiteralPath (Join-Path $RunsRoot $RunId 'state.json') -PathType Leaf)) { Stop-Refused "There is no run '$RunId'." }

Assert-Verified

# Interrupted attempts: the existing fail transition (counted, never a success).
$state = Read-RunState
$recovered = foreach ($name in @($state.steps.Keys)) {
    if ($state.steps[$name].status -ne 'running') { continue }
    $f = Invoke-State @('fail', '-Step', $name, '-Reason', 'interrupted: the session ended before this attempt completed (recorded on resume)')
    if ($f.ExitCode -ne 0) { Stop-Refused "Could not record the interrupted attempt of step '$name': $(("$($f.Stderr) $($f.Stdout)").Trim())" }
    [ordered]@{ step = $name; attempt = $f.Json.attempt; attempts_left = $f.Json.attempts_left }
}
if (@($recovered).Count) { Assert-Verified }   # e.g. a guide written by an interrupted render

$state = Read-RunState
$steps = $state.steps
$skipped = @($steps.Keys | Where-Object { $steps[$_].status -in 'passed', 'approved' })
$status = "$($state.workflow_status)"
$current = "$($state.current_step)"
$canRun = { param($s) $s.status -in 'pending', 'failed' -and -not ($s.status -eq 'failed' -and ([int]$s.attempts -ge [int]$s.max_attempts -or $s['retry_blocked'])) }

$next = switch ($status) {
    'failed' { [ordered]@{ action = 'report-failed'; coordinator_step = 15; steps = @($state.failed_steps) } }
    'rejected' { [ordered]@{ action = 'report-rejected'; coordinator_step = 15 } }
    'completed' {
        $r = $steps.render
        [ordered]@{ action = 'report-completed'; coordinator_step = 17; guide = $r.artifact; guide_sha256 = $r.artifact_sha256; guide_version = $r['version']; plan_sha256 = $steps.approval.plan_sha256 }
    }
    'approved' { [ordered]@{ action = 'render'; coordinator_step = 17; plan_sha256 = $steps.approval.plan_sha256; decision_id = $steps.approval.decision_id } }
    'awaiting_approval' {
        $a = $steps.approval
        $quarantine = @($a['ledger_quarantines'] | Where-Object { $_ -and $_.status -eq 'started' })
        $ledger = Join-Path $RunsRoot $RunId 'approval' 'decisions.jsonl'
        $lines = if (Test-Path -LiteralPath $ledger) { @([System.IO.File]::ReadAllLines($ledger) | Where-Object { $_.Trim() }) } else { @() }
        $plan = $steps.plan
        $n = if ($quarantine.Count) { [ordered]@{ action = 'finish-quarantine'; coordinator_step = 15 } }
             elseif ($lines.Count -gt [int]$a.consumed_through) {
                 # The user submitted a decision before the session ended; decide checks it.
                 [ordered]@{ action = 'apply-decision'; coordinator_step = 15; unconsumed_decisions = $lines.Count - [int]$a.consumed_through }
             }
             else { [ordered]@{ action = 'await-decision'; coordinator_step = 15 } }
        $n.plan_version = $plan['version']
        $n.plan_sha256 = $plan.artifact_sha256
        $n.hash12 = "$($plan.artifact_sha256)".Substring(0, 12)
        $n
    }
    'paused' {
        if ($state.next_step -eq 'research-selection') { [ordered]@{ action = 'select-research'; coordinator_step = 7 } }
        else { [ordered]@{ action = 'report-paused'; coordinator_step = 15; next_step = $state.next_step } }
    }
    default {
        switch ($current) {
            'requirements' {
                $hasInput = Test-Path -LiteralPath (Join-Path $RunsRoot $RunId 'confirmed-input.md') -PathType Leaf
                if (-not $hasInput) { [ordered]@{ action = 'confirm-requirements'; coordinator_step = 1 } }
                else { [ordered]@{ action = 'run-step'; step = 'requirements'; coordinator_step = 5; attempts_left = [int]$steps.requirements.max_attempts - [int]$steps.requirements.attempts } }
            }
            'research' {
                $todo = @($steps.Keys | Where-Object { $_ -like 'research-*' -and (& $canRun $steps[$_]) })
                [ordered]@{ action = 'run-research'; coordinator_step = 9; steps = $todo }
            }
            'render' { [ordered]@{ action = 'render'; coordinator_step = 17; plan_sha256 = $steps.approval.plan_sha256 } }
            default {
                $s = $steps[$current]
                $n = [ordered]@{ action = 'run-step'; step = $current; coordinator_step = $(switch ($current) { 'coverage' { 11 } 'plan' { 12 } 'plan-validation' { 13 } default { $null } }); attempts_left = [int]$s.max_attempts - [int]$s.attempts }
                $rev = @($state['revisions'] | Where-Object { $_ -and $_.status -eq 'open' }) | Select-Object -First 1
                if ($rev) { $n.revision = [ordered]@{ id = $rev.id; base_snapshot = $rev.base_snapshot; feedback = $rev.feedback } }
                $n
            }
        }
    }
}

[ordered]@{
    run_id               = $RunId
    result               = 'resumed'
    workflow_status      = $status
    interrupted_recorded = @($recovered)
    skipped_steps        = $skipped
    next                 = $next
} | ConvertTo-Json -Depth 6
exit 0
