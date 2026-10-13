#Requires -Version 7.0
# Phase 3B tests: user-requested revisions of a passed plan, their separation from
# gate-failure retries, passed-artifact integrity, and URL parsing with apostrophes.
# Dot-sourced by tests/run-tests.ps1, after StateTestKit.ps1 and state.synthesis.tests.ps1
# (which defines Get-Step, Get-Results, and New-ResearchedRun). Agent outputs are fixtures.

function Get-FileSha([string]$RunId, [string]$Rel) { (Get-FileHash -LiteralPath (Join-Path (Get-RunDir $RunId) $Rel) -Algorithm SHA256).Hash.ToLowerInvariant() }
function ConvertTo-Snapshot($Value) { $Value | ConvertTo-Json -Depth 10 -Compress }

# A plan-validation report whose advisory findings have fixed IDs (P1, P2, ...).
function Write-PlanReport([string]$RunId, [object[]]$Findings = @()) {
    $n = 0
    foreach ($f in $Findings) { $n++; $f.id = "P$n" }
    Write-ValidatorReport -RunId $RunId -Report plan -Findings $Findings
}

function Complete-PlanValidation([string]$RunId, [object[]]$Findings = @()) {
    Assert-Ok (Invoke-State @('start', '-RunId', $RunId, '-Step', 'plan-validation')) | Out-Null
    Write-PlanReport $RunId $Findings
    Assert-Ok (Invoke-State @('complete', '-RunId', $RunId, '-Step', 'plan-validation', '-AgentId', 'validator-2'))
}

# A run paused at approval: research, coverage, plan, and plan validation all passed, with
# one advisory finding (P1) the user could pick as a suggested revision.
function New-ValidatedRun {
    $id = New-ResearchedRun
    Complete-Coverage $id
    Complete-Plan $id
    Complete-PlanValidation $id @(New-Finding 'study-planner' 'Theory bullet cites the wrong page.' 'advisory' 'traceability') | Out-Null
    return $id
}

function Write-RevisionRequest([string]$RunId, [hashtable]$Override = @{}) {
    $req = [ordered]@{
        step              = 'plan'
        requested_by      = 'user'
        source            = 'user'
        advisory_findings = @()
        reason            = 'The user wants more hands-on practice on concurrency.'
        feedback          = 'Replace one concurrency theory session with a hands-on exercise.'
        user_confirmation = 'Yes, revise the plan with that change.'
    }
    foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $req.Remove($k) } else { $req[$k] = $Override[$k] } }
    $path = Join-Path (Get-RunDir $RunId) 'revision-request.json'
    $req | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function Invoke-Revise([string]$RunId, [hashtable]$Override = @{}) {
    Invoke-State @('revise', '-RunId', $RunId, '-Step', 'plan', '-RequestFile', (Write-RevisionRequest $RunId $Override))
}

# Plan gate plus plan validation for an open revision; the plan text is made unique.
function Complete-RevisionCycle([string]$RunId, [string]$Marker, [object[]]$Findings = @()) {
    Assert-Ok (Invoke-State @('start', '-RunId', $RunId, '-Step', 'plan')) | Out-Null
    Write-Plan $RunId ((Get-PlanText) + "`nRevision: $Marker")
    Assert-Ok (Invoke-State @('complete', '-RunId', $RunId, '-Step', 'plan', '-AgentId', "planner-$Marker")) | Out-Null
    Complete-PlanValidation $RunId $Findings
}

Write-Section 'requested revisions of a passed plan'

Test-Case 'revision of a passed plan: only the planner reopens, research is preserved, and the new version is validated' {
    $id = New-ValidatedRun
    $before = Read-RunState $id
    $researchSha = @{}
    foreach ($a in 'dotnet', 'data', 'architecture') { $researchSha[$a] = Get-FileSha $id "research/$a.md" }

    $r = Assert-Ok (Invoke-Revise $id)
    Assert-Equal 'opened' $r.result
    Assert-Equal 'rev-001' $r.revision
    Assert-Equal 'study-planner' $r.owner
    Assert-Equal 1 $r.base_version
    Assert-Equal 'plan-validation' (@($r.invalidated) -join ',')
    Assert-Equal 3 $r.attempts_left 'the revised version gets its own gate budget'
    Assert-Equal 2 $r.revisions_left
    Assert-Equal 'plan' $r.current_step

    $s = Read-RunState $id
    $plan = $s.steps.plan
    Assert-Equal 'pending' $plan.status
    Assert-Equal 0 $plan.attempts
    Assert-Equal 'rev-001' $plan.active_revision
    Assert-Equal (ConvertTo-Snapshot $before.steps.plan.history) (ConvertTo-Snapshot $plan.history) 'revise adds nothing to the gate history'
    $rev = $s.revisions[0]
    Assert-Equal 'open' $rev.status
    Assert-Equal 'user' $rev.requested_by
    Assert-Equal $before.steps.plan.artifact_sha256 $rev.base_sha256
    Assert-Match 'hands-on exercise' $rev.feedback
    Assert-True (Test-Path (Join-Path (Get-RunDir $id) 'revisions/rev-001-request.json')) 'request archived'
    Assert-Equal $rev.base_sha256 (Get-FileSha $id 'versions/plan-v1.md') 'the base version is kept as a snapshot'
    Assert-Equal 'pending' $s.steps.'plan-validation'.status
    Assert-Equal 'passed,invalidated' (Get-Results $s.steps.'plan-validation')
    foreach ($name in 'requirements', 'research-dotnet', 'research-data', 'research-architecture', 'coverage') {
        Assert-Equal (ConvertTo-Snapshot $before.steps[$name]) (ConvertTo-Snapshot $s.steps[$name]) "$name must not change"
    }
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation')) "Input step 'plan' is pending"

    Assert-Equal 1 (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan'))).attempt
    Write-Plan $id ((Get-PlanText) + "`nRevised per rev-001.")
    $p = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan', '-AgentId', 'planner-2'))
    Assert-Equal 2 $p.version
    Assert-Equal 'rev-001' $p.revision
    Assert-Equal 'open' (Read-RunState $id).revisions[0].status 'not complete until the plan is validated again'

    $v = Complete-PlanValidation $id
    Assert-Equal 'completed' $v.revisions[0].status
    Assert-Equal 'awaiting_approval' $v.workflow_status
    $s = Read-RunState $id
    $rev = $s.revisions[0]
    Assert-Equal 'completed' $rev.status
    Assert-Equal 2 $rev.result_version
    Assert-Equal $s.steps.plan.artifact_sha256 $rev.result_sha256
    Assert-True ($null -eq $s.steps.plan.active_revision) 'no revision left open'
    $versions = @($s.steps.plan.accepted_versions)
    Assert-Equal '1,2' (($versions | ForEach-Object { $_.version }) -join ',')
    Assert-Equal 'rev-001' $versions[1].revision
    Assert-Equal $versions[1].sha256 (Get-FileSha $id 'versions/plan-v2.md')
    Assert-Equal $rev.base_sha256 (Get-FileSha $id 'versions/plan-v1.md') 'version 1 is still intact'
    foreach ($a in 'dotnet', 'data', 'architecture') { Assert-Equal $researchSha[$a] (Get-FileSha $id "research/$a.md") "research/$a.md untouched" }
    foreach ($name in 'research-dotnet', 'research-data', 'research-architecture', 'coverage') {
        Assert-Equal (ConvertTo-Snapshot $before.steps[$name]) (ConvertTo-Snapshot $s.steps[$name]) "$name untouched by the whole revision"
    }
    Assert-NoLeftovers $id
}

Test-Case 'revision without explicit user authorization is rejected and changes nothing' {
    $id = New-ValidatedRun
    $before = ConvertTo-Snapshot (Read-RunState $id).steps
    $cases = @(
        @{ Name = 'requested by an agent'; Override = @{ requested_by = 'quality-validator' }; Pattern = "'requested_by' must be 'user'" }
        @{ Name = 'requested by the coordinator'; Override = @{ requested_by = 'coordinator' }; Pattern = "'requested_by' must be 'user'" }
        @{ Name = 'no confirmation'; Override = @{ user_confirmation = $null }; Pattern = "'user_confirmation' must quote" }
        @{ Name = 'blank confirmation'; Override = @{ user_confirmation = '  ' }; Pattern = "'user_confirmation' must quote" }
        @{ Name = 'no feedback'; Override = @{ feedback = '' }; Pattern = "'feedback' must state" }
        @{ Name = 'no reason'; Override = @{ reason = $null }; Pattern = "'reason' must say" }
        @{ Name = 'advisory without IDs'; Override = @{ source = 'advisory' }; Pattern = 'must list the confirmed finding IDs' }
        @{ Name = 'unknown advisory finding'; Override = @{ source = 'advisory'; advisory_findings = @('P9') }; Pattern = "'P9' is not an advisory finding" }
        @{ Name = 'wrong step in request'; Override = @{ step = 'research-data' }; Pattern = "'step' must be 'plan'" }
    )
    foreach ($c in $cases) {
        $r = Invoke-Revise $id $c.Override
        Assert-Fails $r $c.Pattern $c.Name
        Assert-Equal 'invalid' $r.Json.result $c.Name
    }
    Assert-Fails (Invoke-State @('revise', '-RunId', $id, '-Step', 'plan', '-RequestFile', 'missing.json')) 'request file not found'
    Assert-Fails (Invoke-State @('revise', '-RunId', $id, '-Step', 'research-data', '-RequestFile', (Write-RevisionRequest $id))) "'research-data' cannot be revised"
    $s = Read-RunState $id
    Assert-Equal $before (ConvertTo-Snapshot $s.steps) 'rejected requests leave every step unchanged'
    Assert-Equal 0 @($s['revisions'] | Where-Object { $_ }).Count 'nothing is recorded'
    Assert-True (-not (Test-Path (Join-Path (Get-RunDir $id) 'revisions'))) 'no request archived'
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) "already passed. To change it, record a user-requested revision"

    # A plan that passed its gate but is not yet validated cannot be revised either.
    $id2 = New-ResearchedRun
    Complete-Coverage $id2
    Complete-Plan $id2
    Assert-Fails (Invoke-Revise $id2) "only after it is validated; not passed yet: plan-validation"
}

Test-Case 'multiple sequential revisions: unique IDs, one open at a time, each based on the latest version' {
    $id = New-ValidatedRun
    Assert-Ok (Invoke-Revise $id) | Out-Null
    Assert-Fails (Invoke-Revise $id) "Revision 'rev-001' is still open"
    $v = Complete-RevisionCycle $id 'one' @(New-Finding 'study-planner' 'Session 3 exercise is sized at 60 min but given 50.' 'advisory' 'time_budget')
    Assert-Equal 'P1' $v.suggested_revisions[0].id 'advisory findings are offered, not applied'
    Assert-Equal 'passed' (Get-Step $id 'plan').status 'an advisory finding never reopens the plan by itself'

    # The second revision is the advisory finding the user picked from the current report.
    $r = Assert-Ok (Invoke-Revise $id @{ source = 'advisory'; advisory_findings = @('P1'); reason = 'User accepted suggestion P1.'; feedback = 'Cut the dotnet-stack step so the exercise fits 50 minutes.' })
    Assert-Equal 'rev-002' $r.revision
    Assert-Equal 2 $r.base_version
    Assert-Equal 1 $r.revisions_left
    Complete-RevisionCycle $id 'two' | Out-Null

    $s = Read-RunState $id
    Assert-Equal 'rev-001,rev-002' ((@($s.revisions) | ForEach-Object { $_.id }) -join ',')
    Assert-Equal 'completed,completed' ((@($s.revisions) | ForEach-Object { $_.status }) -join ',')
    Assert-Equal 'advisory' $s.revisions[1].source
    Assert-Equal 'P1' (@($s.revisions[1].advisory_findings) -join ',')
    Assert-Equal 'rev-001,rev-002' (@($s.steps.plan.revisions) -join ',')
    Assert-Equal ',rev-001,rev-002' ((@($s.steps.plan.accepted_versions) | ForEach-Object { $_.revision }) -join ',')
    Assert-Equal $s.revisions[0].result_sha256 $s.revisions[1].base_sha256 'each revision starts from the latest accepted version'
    $shas = @(1..3 | ForEach-Object { Get-FileSha $id "versions/plan-v$_.md" })
    Assert-Equal 3 @($shas | Select-Object -Unique).Count 'three distinct snapshots'
    Assert-Equal $shas[2] $s.steps.plan.artifact_sha256
}

Test-Case 'a revised plan that fails its gates is retried within its own budget, then validated' {
    $id = New-ValidatedRun
    Assert-Ok (Invoke-Revise $id) | Out-Null
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id (Get-PlanText -SessionMinutes 120)
    $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')
    Assert-Fails $r 'Over budget'
    Assert-Equal 2 $r.Json.attempts_left

    Assert-Equal 2 (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan'))).attempt
    Write-Plan $id ((Get-PlanText) + "`nRevised.")
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) | Out-Null

    # Plan validation blames the planner: the revision's own budget is charged again.
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation')) | Out-Null
    Write-PlanReport $id @(New-Finding 'study-planner' 'The revision ignored the confirmed feedback.' 'blocking' 'requirements_mismatch')
    $f = Invoke-State @('complete', '-RunId', $id, '-Step', 'plan-validation')
    Assert-Equal 'plan' $f.Json.retry[0].step
    Assert-Equal 1 $f.Json.retry[0].attempts_left
    Assert-Equal 'open' (Read-RunState $id).revisions[0].status

    Assert-Equal 3 (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan'))).attempt
    Write-Plan $id ((Get-PlanText) + "`nRevised again.")
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) | Out-Null
    $v = Complete-PlanValidation $id
    Assert-Equal 'completed' $v.revisions[0].status
    $s = Read-RunState $id
    $last = @($s.steps.plan.accepted_versions)[-1]
    Assert-Equal 3 $last.version 'v2 passed the plan gate but was rejected by validation; v3 is the validated one'
    Assert-Equal 3 $last.attempt
}

Test-Case 'gate-failure history is kept separate from revision history' {
    $id = New-ResearchedRun
    Complete-Coverage $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id (Get-PlanText -SessionMinutes 120)
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) 'Over budget'
    Complete-Plan $id
    Complete-PlanValidation $id | Out-Null
    $before = Read-RunState $id
    Assert-Equal 'failed,passed' (Get-Results $before.steps.plan)
    Assert-Equal 2 $before.steps.plan.attempts

    Assert-Ok (Invoke-Revise $id) | Out-Null
    $s = Read-RunState $id
    Assert-Equal (ConvertTo-Snapshot $before.steps.plan.history) (ConvertTo-Snapshot $s.steps.plan.history) 'the retry history is neither consumed nor reset'
    Assert-Equal 2 $s.revisions[0].base_attempt 'the base version records the attempt it passed on'
    Assert-True (-not $s.revisions[0].Contains('attempts')) 'a revision record holds no gate attempts'

    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id (Get-PlanText -SessionMinutes 120)
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) 'Over budget'
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id ((Get-PlanText) + "`nRevised.")
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) | Out-Null
    $h = @((Read-RunState $id).steps.plan.history)
    Assert-Equal 'failed,passed,failed,passed' (($h | ForEach-Object { $_.result }) -join ',')
    Assert-Equal '1,1,2,2' (($h | ForEach-Object { $_.version }) -join ',')
    Assert-Equal ',,rev-001,rev-001' (($h | ForEach-Object { $_['revision'] }) -join ',')
    Assert-Equal '1,2,1,2' (($h | ForEach-Object { $_.attempt }) -join ',') 'each version has its own attempt numbering'
}

Test-Case 'downstream invalidation and revalidation: a research finding during a revision re-runs only that agent' {
    $id = New-ValidatedRun
    Assert-Ok (Invoke-Revise $id) | Out-Null
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id ((Get-PlanText) + "`nRevised.")
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) | Out-Null
    $data = ConvertTo-Snapshot (Get-Step $id 'research-data')

    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation')) | Out-Null
    Write-PlanReport $id @(New-Finding 'architecture-researcher' 'Claims exactly-once delivery; the cited page says at-least-once.' 'blocking' 'conflicting_findings')
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan-validation'))
    $s = Read-RunState $id
    Assert-Equal 'failed' $s.steps.'research-architecture'.status
    foreach ($name in 'coverage', 'plan', 'plan-validation') { Assert-Equal 'pending' $s.steps[$name].status $name }
    Assert-Equal 'open' $s.revisions[0].status 'the revision stays open while its chain is rebuilt'
    Assert-Equal 'rev-001' $s.steps.plan.active_revision

    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-architecture')) | Out-Null
    Write-Research $id 'architecture' ((Get-ResearchText -Area architecture) + "`nCorrected.")
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-architecture')) | Out-Null
    Complete-Coverage $id
    $v = Complete-RevisionCycle $id 'rebuilt'
    Assert-Equal 'completed' $v.revisions[0].status
    $s = Read-RunState $id
    Assert-Equal 3 $s.revisions[0].result_version 'v2 was invalidated; the validated plan is v3'
    Assert-Equal $data (ConvertTo-Snapshot $s.steps.'research-data') 'unaffected research is untouched'
}

Test-Case 'revision limit: a fourth revision is refused; a revision out of attempts fails the run but keeps the old version' {
    $id = New-ValidatedRun
    foreach ($n in 1..3) {
        Assert-Ok (Invoke-Revise $id @{ feedback = "Change number $n." }) | Out-Null
        Complete-RevisionCycle $id "limit-$n" | Out-Null
    }
    $before = ConvertTo-Snapshot (Read-RunState $id).steps
    Assert-Fails (Invoke-Revise $id) "Revision limit reached: step 'plan' has used all 3 revisions"
    Assert-Equal $before (ConvertTo-Snapshot (Read-RunState $id).steps) 'a refused revision changes nothing'

    $id = New-ValidatedRun
    $base = Get-FileSha $id 'plan.md'
    Assert-Ok (Invoke-Revise $id) | Out-Null
    foreach ($n in 1..3) {
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
        Write-Plan $id (Get-PlanText -SessionMinutes 120)
        $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')
    }
    Assert-Equal 'failed' $r.Json.workflow_status
    $s = Read-RunState $id
    Assert-Equal 'failed' $s.revisions[0].status
    Assert-Match 'out of attempts: plan' $s.revisions[0].failure_reason
    Assert-Equal $base (Get-FileSha $id 'versions/plan-v1.md') 'the last accepted version is kept'
    Assert-Fails (Invoke-Revise $id) "'plan' is failed; only a passed artifact can be revised"
}

Write-Section 'passed-artifact integrity'

Test-Case 'manual modification of a passed artifact blocks dependents until it is restored' {
    $id = New-ResearchedRun
    Complete-Coverage $id
    Complete-Plan $id
    $original = Get-FileSha $id 'plan.md'
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id) 'plan.md') -Value 'Manual edit.'

    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation')) 'Integrity violation: plan.md changed after it passed'
    $s = Read-RunState $id
    Assert-Equal 'blocked' $s.workflow_status
    Assert-Equal 'plan' $s.integrity.violations[0].step
    Assert-Equal 'passed' $s.steps.plan.status 'the edit is not silently accepted as a new version'
    Assert-Equal 0 $s.steps.'plan-validation'.attempts
    $v = Invoke-State @('verify', '-RunId', $id)
    Assert-Fails $v
    Assert-Equal 'violated' $v.Json.result
    Assert-Fails (Invoke-State @('resolve', '-RunId', $id, '-Step', 'coverage', '-Resolution', 'restore')) "'coverage' has no integrity violation"

    $r = Assert-Ok (Invoke-State @('resolve', '-RunId', $id, '-Step', 'plan', '-Resolution', 'restore'))
    Assert-Equal 'ok' $r.integrity
    Assert-Equal $original (Get-FileSha $id 'plan.md') 'the accepted version is back'
    Assert-Match 'Manual edit\.' (Get-Content -LiteralPath (Join-Path (Get-RunDir $id) $r.modified_copy.Substring("runs/$id/".Length)) -Raw) 'the edit is kept for audit'
    $s = Read-RunState $id
    Assert-Equal 'restore' $s.integrity.events[0].resolution
    Assert-Equal 'in_progress' $s.workflow_status
    Assert-Equal 'ok' (Assert-Ok (Invoke-State @('verify', '-RunId', $id))).result
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation')) | Out-Null
}

Test-Case 'a manually modified research artifact is never propagated; discarding it re-runs only that agent' {
    $id = New-ResearchedRun
    Complete-Coverage $id
    $dataBefore = ConvertTo-Snapshot (Get-Step $id 'research-data')
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id) 'research/dotnet.md') -Value 'Unreviewed claim.'

    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) 'Integrity violation: research/dotnet.md changed after it passed'
    $s = Read-RunState $id
    Assert-Equal 'passed' $s.steps.coverage.status 'the edit is not treated as a legitimate input change'
    Assert-Equal 'blocked' $s.workflow_status
    Assert-Fails (Invoke-State @('resolve', '-RunId', $id, '-Step', 'requirements', '-Resolution', 'discard')) 'no integrity violation'

    $r = Assert-Ok (Invoke-State @('resolve', '-RunId', $id, '-Step', 'research-dotnet', '-Resolution', 'discard'))
    Assert-Equal 'pending' $r.step_status
    $s = Read-RunState $id
    Assert-Equal 'passed,discarded' (Get-Results $s.steps.'research-dotnet')
    Assert-Equal 0 $s.steps.'research-dotnet'.attempts 'a discard is not a failed attempt'
    Assert-Equal 'pending' $s.steps.coverage.status 'coverage now depends on research that will be re-run'
    Assert-Equal $dataBefore (ConvertTo-Snapshot $s.steps.'research-data')
    Assert-Equal 'research' $s.current_step
    Assert-Equal 1 (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-dotnet'))).attempt

    # requirements.md can only be restored; discarding it would need a requirements re-run.
    $id = New-SelectedRun @('data')
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id) 'requirements.md') -Value 'edited'
    Assert-Fails (Invoke-State @('resolve', '-RunId', $id, '-Step', 'requirements', '-Resolution', 'discard')) 'can only be restored'
    Assert-Fails (Invoke-Revise $id) 'Integrity violation'
}

Write-Section 'URL parsing'

Test-Case 'URLs containing apostrophes are parsed whole, counted as distinct sources, and traced exactly' {
    $id = New-SelectedRun
    Complete-Research $id @('dotnet', 'data')
    $one = "https://learn.microsoft.com/dotnet/architecture/communication#asynchronous-microservice-integration-enforces-microservice's-autonomy"
    # Identical up to the apostrophe: the old parser truncated both to the same URL (2 sources).
    $two = "https://learn.microsoft.com/dotnet/architecture/communication#asynchronous-microservice-integration-enforces-microservice's-data"
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-architecture')) | Out-Null
    $text = (Get-ResearchText -Area architecture -Sources @($one, $two)) -replace '## Gaps and Limitations', "- Quoted: 'https://github.com/dotnet/quoted'.`n`n## Gaps and Limitations"
    Write-Research $id 'architecture' $text
    $r = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-architecture'))
    Assert-Equal 3 $r.source_count 'two apostrophe URLs sharing a prefix plus a quoted URL are 3 distinct sources'

    Complete-Coverage $id
    $truncated = 'https://learn.microsoft.com/dotnet/architecture/communication#asynchronous-microservice-integration-enforces-microservice'
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id (Get-PlanText -ExtraUrl $truncated)
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) ('Untraceable source: ' + [regex]::Escape($truncated) + ' does not')
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id (Get-PlanText -ExtraUrl "[communication]($one)")
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) | Out-Null
}
