#Requires -Version 7.0
# Phase 6 tests: resuming a run after a Claude Code session ended (scripts/resume-run.ps1).
# Dot-sourced by tests/run-tests.ps1 after render.tests.ps1 (New-ApprovedRun, Invoke-Render,
# Invoke-Revise, ...). Agent outputs are fixtures.

$script:Resumer = (Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'resume-run.ps1')).Path

function Invoke-Resume([string]$RunId) {
    $output = & pwsh -NoProfile -NonInteractive -File $script:Resumer -RunId $RunId -RunsRoot $script:RunsRoot -StateScript $script:StateScript 2>&1
    $code = $LASTEXITCODE
    $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $json = $null
    if ($stdout.Trim()) { try { $json = $stdout | ConvertFrom-Json -AsHashtable } catch { } }
    [pscustomobject]@{ ExitCode = $code; Stdout = $stdout; Json = $json }
}

function Assert-Resumed($Result, [string]$Action) {
    Assert-Equal 0 $Result.ExitCode $Result.Stdout
    Assert-Equal 'resumed' $Result.Json.result
    Assert-Equal $Action $Result.Json.next.action $Result.Stdout
    return $Result.Json
}

function Get-StepsSnapshot([string]$RunId, [string[]]$Names) {
    $s = Read-RunState $RunId
    ($Names | ForEach-Object { $s.steps[$_] | ConvertTo-Json -Depth 10 -Compress }) -join "`n"
}

Write-Section 'resume after a session restart (Phase 6)'

Test-Case 'resume after requirements: research selection is next' {
    $id = New-PassedRun
    $r = Assert-Resumed (Invoke-Resume $id) 'select-research'
    Assert-Equal 7 $r.next.coordinator_step
    Assert-Equal 'requirements' (@($r.skipped_steps) -join ',')
    Assert-Equal 0 @($r.interrupted_recorded).Count
}

Test-Case 'resume after research: only unfinished research or the next step runs; passed research is not repeated' {
    $id = New-ResearchedRun
    $research = @('research-dotnet', 'research-data', 'research-architecture')
    $before = Get-StepsSnapshot $id $research
    $shas = @($research | ForEach-Object { Get-FileSha $id "research/$($_.Substring(9)).md" })
    $r = Assert-Resumed (Invoke-Resume $id) 'run-step'
    Assert-Equal 'coverage' $r.next.step
    Assert-Equal 11 $r.next.coordinator_step
    foreach ($s in $research) { Assert-True (@($r.skipped_steps) -contains $s) "$s is skipped" }
    Assert-Equal $before (Get-StepsSnapshot $id $research) 'research steps are untouched'
    Assert-Equal ($shas -join ',') ((@($research | ForEach-Object { Get-FileSha $id "research/$($_.Substring(9)).md" })) -join ',')

    # Partly done: only the research steps that have not passed are named.
    $id2 = New-SelectedRun
    Complete-Research $id2 @('dotnet')
    $r = Assert-Resumed (Invoke-Resume $id2) 'run-research'
    Assert-Equal 'research-data,research-architecture' (@($r.next.steps) -join ',')
    Assert-True (@($r.skipped_steps) -contains 'research-dotnet')
}

Test-Case 'resume after the plan passed: plan validation is next' {
    $id = New-ResearchedRun
    Complete-Coverage $id
    Complete-Plan $id
    $r = Assert-Resumed (Invoke-Resume $id) 'run-step'
    Assert-Equal 'plan-validation' $r.next.step
    Assert-Equal 13 $r.next.coordinator_step
    Assert-Equal 3 $r.next.attempts_left
}

Test-Case 'resume while awaiting approval: the plan waits for a new user decision; captured evidence is only handed to decide' {
    $id = New-ValidatedRun
    $sha = Get-FileSha $id 'plan.md'
    $r = Assert-Resumed (Invoke-Resume $id) 'await-decision'
    Assert-Equal $sha $r.next.plan_sha256
    Assert-Equal $sha.Substring(0, 12) $r.next.hash12
    Assert-Equal 1 $r.next.plan_version
    $s = Read-RunState $id
    Assert-Equal 'awaiting_decision' $s.steps.approval.status 'resume does not decide'
    Assert-True (-not (Test-Path (Get-LedgerFile $id))) 'resume records no evidence'

    # The user had submitted a decision before the session ended: it is pointed out, not applied.
    Add-TestOnlyLedgerEntry $id 'approve' | Out-Null
    $r = Assert-Resumed (Invoke-Resume $id) 'apply-decision'
    Assert-Equal 1 $r.next.unconsumed_decisions
    Assert-Equal 'awaiting_decision' (Read-RunState $id).steps.approval.status 'still not applied by resume'
    Assert-Equal 0 (Read-RunState $id).steps.approval.consumed_through
}

Test-Case 'resume after approval, before render: render is next and approval is not requested again' {
    $id = New-ApprovedRun
    $approval = Get-StepsSnapshot $id @('approval')
    $r = Assert-Resumed (Invoke-Resume $id) 'render'
    Assert-Equal 17 $r.next.coordinator_step
    Assert-Equal 'dec-001' $r.next.decision_id
    Assert-Equal (Get-FileSha $id 'plan.md') $r.next.plan_sha256
    Assert-Equal $approval (Get-StepsSnapshot $id @('approval')) 'the approval is unchanged'
}

Test-Case 'resume a completed run: the finished guide is reported, not regenerated' {
    $id = New-ApprovedRun
    Assert-Equal 'passed' (Invoke-Render $id).Json.result
    $guideSha = Get-FileSha $id 'guide.html'
    $render = Get-StepsSnapshot $id @('render')
    $r = Assert-Resumed (Invoke-Resume $id) 'report-completed'
    Assert-Equal $guideSha $r.next.guide_sha256
    Assert-Match "runs/$id/guide\.html" $r.next.guide
    Assert-Equal $guideSha (Get-FileSha $id 'guide.html') 'the guide is not rewritten'
    Assert-Equal $render (Get-StepsSnapshot $id @('render')) 'render is not run again'
}

Test-Case 'resume after an interrupted step: the attempt is recorded as failed, budgets are kept, only that step runs again' {
    # A validator interrupted mid-attempt.
    $id = New-ResearchedRun
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    $r = Assert-Resumed (Invoke-Resume $id) 'run-step'
    Assert-Equal 'coverage' (@($r.interrupted_recorded)[0].step)
    Assert-Equal 2 (@($r.interrupted_recorded)[0].attempts_left)
    Assert-Equal 'coverage' $r.next.step
    Assert-Equal 2 $r.next.attempts_left
    $c = (Read-RunState $id).steps.coverage
    Assert-Equal 'failed' $c.status
    Assert-Equal 1 $c.attempts 'the interrupted attempt counts; it is not a success'
    Assert-Match 'interrupted' (@($c.history)[-1].reasons -join ' ')
    Assert-Equal 2 (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage'))).attempt 'the existing retry continues'

    # One of several parallel research agents interrupted: only it is retried.
    $id2 = New-SelectedRun
    Complete-Research $id2 @('dotnet')
    $dotnet = Get-StepsSnapshot $id2 @('research-dotnet')
    Assert-Ok (Invoke-State @('start', '-RunId', $id2, '-Step', 'research-data')) | Out-Null
    $r = Assert-Resumed (Invoke-Resume $id2) 'run-research'
    Assert-Equal 'research-data' (@($r.interrupted_recorded)[0].step)
    Assert-Equal 'research-data,research-architecture' (@($r.next.steps) -join ',')
    Assert-Equal $dotnet (Get-StepsSnapshot $id2 @('research-dotnet')) 'passed research is untouched'

    # The planner interrupted during an open revision: the revision context is returned.
    $id3 = New-ValidatedRun
    Assert-Ok (Invoke-Revise $id3) | Out-Null
    Assert-Ok (Invoke-State @('start', '-RunId', $id3, '-Step', 'plan')) | Out-Null
    $r = Assert-Resumed (Invoke-Resume $id3) 'run-step'
    Assert-Equal 'plan' $r.next.step
    Assert-Equal 'rev-001' $r.next.revision.id
    Assert-Match 'plan-v1\.md$' $r.next.revision.base_snapshot
    Assert-Equal 'open' (Read-RunState $id3).revisions[0].status 'the revision stays open'

    # Interrupted on the last attempt: the step is exhausted and the run reports failure.
    $id4 = New-ResearchedRun
    foreach ($n in 1..2) {
        Assert-Ok (Invoke-State @('start', '-RunId', $id4, '-Step', 'coverage')) | Out-Null
        Assert-Ok (Invoke-State @('fail', '-RunId', $id4, '-Step', 'coverage', '-Reason', "attempt $n failed")) | Out-Null
    }
    Assert-Ok (Invoke-State @('start', '-RunId', $id4, '-Step', 'coverage')) | Out-Null
    $r = Assert-Resumed (Invoke-Resume $id4) 'report-failed'
    Assert-Equal 'failed' $r.workflow_status
    Assert-Equal 'coverage' (@($r.next.steps) -join ',')
}

Test-Case 'resume is refused while an integrity violation is unresolved, and changes nothing' {
    $id = New-ResearchedRun
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id) 'research/data.md') -Value "`nEdited outside the workflow." -Encoding utf8NoBOM
    $r = Invoke-Resume $id
    Assert-Equal 1 $r.ExitCode
    Assert-Equal 'refused' $r.Json.result
    Assert-Match 'Integrity violation' $r.Json.reason
    Assert-Match 'research/data\.md changed after it passed' (@($r.Json.details) -join ' ')
    $s = Read-RunState $id
    Assert-Equal 'running' $s.steps.coverage.status 'no interrupted attempt is recorded while the run is blocked'
    Assert-Equal 'blocked' $s.workflow_status
    Assert-Equal 'refused' (Invoke-Resume 'no-such-run').Json.result
}
