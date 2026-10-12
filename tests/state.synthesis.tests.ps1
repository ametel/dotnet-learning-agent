#Requires -Version 7.0
# Phase 3A tests: mandatory topics, global coverage gate, study-plan gate, plan-validation gate,
# targeted retries, downstream invalidation, and retry exhaustion.
# Dot-sourced by tests/run-tests.ps1, after StateTestKit.ps1. Agent outputs are fixtures.

function Get-Step([string]$RunId, [string]$Name) { (Read-RunState $RunId).steps[$Name] }
function Get-Results($Entry) { (@($Entry.history) | ForEach-Object { $_.result }) -join ',' }

# A run with all research passed (all three areas unless told otherwise).
function New-ResearchedRun([string[]]$Areas = @('dotnet', 'data', 'architecture'), [string]$Budget = '15') {
    $id = New-SelectedRun -Areas $Areas -Budget $Budget
    Complete-Research $id $Areas
    return $id
}

Write-Section 'mandatory topics and time budget (requirements front matter)'

Test-Case 'requirements gate checks mandatory_topics and time_budget_hours' {
    $cases = @(
        @{ Name = 'no mandatory topics'; Text = (Get-RequirementsText -Mandatory @()); Pattern = "non-empty 'mandatory_topics'" }
        @{ Name = 'bad budget'; Text = (Get-RequirementsText -Budget 'a few'); Pattern = "time_budget_hours' must be a positive number" }
        @{ Name = 'missing budget'; Text = (Get-RequirementsText -Budget ''); Pattern = "time_budget_hours' must be a positive number" }
        @{ Name = 'topic not in gaps'; Text = ((Get-RequirementsText) -replace '- EF Core performance \(stated\)', '- other' -replace '- EF Core performance \| High', '- other | High'); Pattern = "'EF Core performance' does not appear" }
    )
    foreach ($c in $cases) {
        $id = New-Run
        Write-ConfirmedInput $id
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
        Write-Requirements $id $c.Text
        Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'requirements')) $c.Pattern $c.Name
    }
}

Test-Case 'requirements record mandatory topics; an unspecified budget is stored as null' {
    $id = New-Run
    Write-ConfirmedInput $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    Write-Requirements $id (Get-RequirementsText -Budget 'unspecified')
    $r = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'requirements'))
    Assert-Equal 'async internals|concurrency|EF Core performance|system design' (@($r.mandatory_topics) -join '|')
    Assert-True ($null -eq (Get-Step $id 'requirements').time_budget_hours) 'unspecified budget must be null'
}

Write-Section 'selection coverage map'

Test-Case 'selection must map every mandatory topic to an assigned research topic' {
    $id = New-PassedRun
    # Data not selected: 'EF Core performance' is mandatory but unmapped -> stop before research.
    $sel = Get-DefaultSelection @('dotnet', 'architecture')
    Assert-Fails (Invoke-State @('select', '-RunId', $id, '-SelectionFile', (Write-Selection $id $sel))) "'EF Core performance' is not covered by any selected research agent"
    $sel = Get-DefaultSelection
    $sel.coverage[0].research_topics = @('Not an assigned topic')
    Assert-Fails (Invoke-State @('select', '-RunId', $id, '-SelectionFile', (Write-Selection $id $sel))) 'not a topic assigned to a selected agent'
    $sel = Get-DefaultSelection
    $sel.coverage += @{ mandatory_topic = 'behavioral interviews'; research_topics = @('System design') }
    Assert-Fails (Invoke-State @('select', '-RunId', $id, '-SelectionFile', (Write-Selection $id $sel))) "'behavioral interviews' is not a confirmed mandatory topic"
    Assert-True ($null -eq (Read-RunState $id).research) 'invalid selections leave research unselected'
}

Write-Section 'successful coverage and synthesis'

Test-Case 'full path: research -> coverage -> plan -> plan-validation passes and pauses for approval' {
    $id = New-ResearchedRun
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) "Input step 'coverage' is pending"
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    Write-ValidatorReport -RunId $id -Report coverage -Findings @(New-Finding 'coordinator' 'ASP.NET Core review not researched.' 'advisory' 'optional_topic')
    $c = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage', '-AgentId', 'v1'))
    Assert-Equal 1 $c.advisory_findings
    Assert-Equal 'plan' (Read-RunState $id).current_step

    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id (Get-PlanText)
    $p = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan', '-AgentId', 'p1'))
    Assert-Equal 9 $p.planned_hours

    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation')) | Out-Null
    Write-ValidatorReport -RunId $id -Report plan
    $v = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan-validation', '-AgentId', 'v2'))
    Assert-Equal 'paused' $v.workflow_status
    Assert-Equal 'approval (not implemented yet)' $v.next_step

    $s = Read-RunState $id
    foreach ($name in 'coverage', 'plan', 'plan-validation') {
        Assert-Equal 'passed' $s.steps[$name].status $name
        Assert-Equal 1 $s.steps[$name].attempts $name
        Assert-Match '^[0-9a-f]{64}$' $s.steps[$name].inputs_sha256.'requirements.md' $name
    }
    Assert-Match '^[0-9a-f]{64}$' $s.steps.'plan-validation'.inputs_sha256.'plan.md'
    $archived = @(Get-ChildItem (Join-Path (Get-RunDir $id) 'validation/history') -File).Name
    Assert-True (@($archived -like 'coverage-attempt1-*.json').Count -eq 1) "coverage report archived: $archived"
    Assert-True (@($archived -like 'plan-validation-attempt1-*.md').Count -eq 1) "plan report summary archived: $archived"
    Assert-NoLeftovers $id
}

Test-Case 'optional topic absent: an advisory finding never fails a gate, and cannot be blocking' {
    $id = New-ResearchedRun
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    Write-ValidatorReport -RunId $id -Report coverage -Findings @(New-Finding 'dotnet-researcher' 'Optional ASP.NET Core review is absent.' 'blocking' 'optional_topic')
    $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage')
    Assert-Fails $r 'an optional topic can never be blocking'
    Assert-Equal 'coverage' $r.Json.retry[0].step 'a malformed report retries only the validator'
    Assert-Equal 'passed' (Get-Step $id 'research-dotnet').status 'research is not blamed for a bad report'

    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    Write-ValidatorReport -RunId $id -Report coverage -Findings @(New-Finding 'dotnet-researcher' 'Optional ASP.NET Core review is absent.' 'advisory' 'optional_topic')
    $ok = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage'))
    Assert-Equal 2 $ok.attempt
}

Write-Section 'missing mandatory topic and targeted research retry'

Test-Case 'missing mandatory topic: only the owning research agent is reopened; others are untouched' {
    $id = New-ResearchedRun
    $before = Read-RunState $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    Write-ValidatorReport -RunId $id -Report coverage -Statuses @{ 'EF Core performance' = 'missing' } -Findings @(
        New-Finding 'data-researcher' 'EF Core performance section only lists links; no findings.' -Topic 'EF Core performance')
    $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage')
    Assert-Fails $r 'data-researcher: \[missing_coverage\]'
    Assert-Equal 'research-data' (@($r.Json.retry | ForEach-Object { $_.step }) -join ',')
    Assert-Equal 2 $r.Json.retry[0].attempts_left
    Assert-Equal 'in_progress' $r.Json.workflow_status

    $s = Read-RunState $id
    $data = $s.steps.'research-data'
    Assert-Equal 'failed' $data.status
    Assert-Equal 'passed,failed' (Get-Results $data)
    Assert-Equal 'coverage' $data.history[1].gate
    Assert-Equal 'pending' $s.steps.coverage.status 'coverage is invalidated, not failed'
    Assert-Equal 0 $s.steps.coverage.attempts 'invalidation gives coverage a fresh budget'
    Assert-Equal 'failed,invalidated' (Get-Results $s.steps.coverage)
    foreach ($other in 'research-dotnet', 'research-architecture') {
        Assert-Equal ($before.steps[$other] | ConvertTo-Json -Depth 10) ($s.steps[$other] | ConvertTo-Json -Depth 10) "$other must not change"
    }
    Assert-Equal 'research' $s.current_step
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) "Input step 'research-data' is failed"
}

Test-Case 'targeted research retry: the reopened agent re-runs, then coverage passes on a fresh budget' {
    $id = New-ResearchedRun
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    Write-ValidatorReport -RunId $id -Report coverage -Statuses @{ 'concurrency' = 'partial' } -Findings @(
        New-Finding 'dotnet-researcher' 'Concurrency section has no interview questions.' -Topic 'concurrency')
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage'))

    $r = Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-dotnet'))
    Assert-Equal 2 $r.attempt
    Write-Research $id 'dotnet' ((Get-ResearchText -Area dotnet) + "`n`nImproved concurrency section.")
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-dotnet')) | Out-Null

    $c = Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage'))
    Assert-Equal 1 $c.attempt 'coverage restarts at attempt 1 for its new inputs'
    Write-ValidatorReport -RunId $id -Report coverage
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    $s = Read-RunState $id
    Assert-Equal 1 $s.steps.'research-data'.attempts
    Assert-Equal 1 $s.steps.'research-architecture'.attempts
    Assert-Equal 2 $s.steps.'research-dotnet'.attempts
    Assert-Equal 'plan' $s.current_step
}

Test-Case 'coordinator-owned blocking finding stops the branch without re-running anyone' {
    $id = New-ResearchedRun
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    Write-ValidatorReport -RunId $id -Report coverage -Statuses @{ 'system design' = 'partial' } -Findings @(
        New-Finding 'coordinator' 'System design was mapped to a topic that only covers caching.' 'blocking' 'misplaced_responsibility' 'system design'
        New-Finding 'architecture-researcher' 'Caching section lacks sources.' 'blocking' 'unsupported_claim' 'system design')
    $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage')
    Assert-Fails $r 'coordinator: \[misplaced_responsibility\]'
    Assert-Equal 0 @($r.Json.retry).Count 'nothing is retried when the selection itself is wrong'
    Assert-Equal 'architecture-researcher,coordinator' (@($r.Json.blocked | ForEach-Object { $_.owner } | Sort-Object) -join ',')
    $s = Read-RunState $id
    Assert-Equal 'passed' $s.steps.'research-architecture'.status
    Assert-Equal 'failed' $s.workflow_status
    Assert-Equal 'coverage' (@($s.failed_steps) -join ',')
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) 'non-retryable'
}

Test-Case 'malformed validator reports retry only the validator' {
    $cases = @(
        @{ Name = 'no summary'; Args = @{ NoSummary = $true }; Pattern = 'Human-readable summary missing' }
        @{ Name = 'topic not assessed'; Args = @{ Mandatory = @('async internals', 'concurrency', 'system design') }; Pattern = "does not assess mandatory topic 'EF Core performance'" }
        @{ Name = 'verdict inconsistent'; Args = @{ Verdict = 'fail' }; Pattern = "'verdict' is 'fail' but there is no blocking finding" }
        @{ Name = 'missing without finding'; Args = @{ Statuses = @{ 'concurrency' = 'missing' } }; Pattern = "'concurrency' is 'missing' but has no blocking finding" }
        @{ Name = 'unknown owner'; Args = @{ Findings = @(New-Finding 'study-planner' 'x') }; Pattern = "'owner' must be one of" }
    )
    $id = New-ResearchedRun
    $n = 0
    foreach ($c in $cases) {
        if (++$n -gt 3) { $id = New-ResearchedRun; $n = 1 }
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
        $a = $c.Args
        Write-ValidatorReport -RunId $id -Report coverage @a
        $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage')
        Assert-Fails $r $c.Pattern $c.Name
        Assert-Equal 'coverage' (@($r.Json.retry | ForEach-Object { $_.step }) -join ',') $c.Name
        Assert-Equal 'passed' (Get-Step $id 'research-data').status $c.Name
    }
}

Write-Section 'study-plan gate'

Test-Case 'plan gate: over budget, budget mismatch, wrong source, missing topic, wrong research inputs' {
    $cases = @(
        @{ Name = 'over budget'; Text = (Get-PlanText -SessionMinutes 120); Pattern = 'Over budget: schedule totals 18 h' }
        @{ Name = 'budget differs from confirmed'; Text = (Get-PlanText -Budget '20'); Pattern = 'budget_hours 20 differs from the confirmed time_budget_hours 15' }
        @{ Name = 'wrong source reference'; Text = (Get-PlanText -ExtraUrl 'https://example.org/invented-article'); Pattern = 'Untraceable source: https://example.org/invented-article' }
        @{ Name = 'missing mandatory topic'; Text = (Get-PlanText -OmitTopics 'concurrency'); Pattern = "no heading '### concurrency'" }
        @{ Name = 'planned hours mismatch'; Text = (Get-PlanText -PlannedHours '5'); Pattern = "planned_hours '5' does not match" }
        @{ Name = 'research inputs'; Text = ((Get-PlanText) -replace '  - research/data.md', '  - research/cloud.md'); Pattern = "'research/cloud.md', which is not a selected research artifact" }
        @{ Name = 'missing interview session'; Text = ((Get-PlanText) -replace '\| system design \| interview \|', '| system design | practice |'); Pattern = "no 'interview' session for mandatory topic 'system design'" }
    )
    foreach ($c in $cases) {
        $id = New-ResearchedRun
        Complete-Coverage $id
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
        Write-Plan $id $c.Text
        $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')
        Assert-Fails $r $c.Pattern $c.Name
        Assert-Equal 'plan' $r.Json.retry[0].step $c.Name
        Assert-Equal 2 $r.Json.attempts_left $c.Name
        Assert-Equal 'passed' (Get-Step $id 'coverage').status "$($c.Name): coverage untouched"
    }
}

Test-Case 'unspecified confirmed budget: the plan declares its own and must stay within it' {
    $id = New-ResearchedRun -Budget 'unspecified'
    Complete-Coverage $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id (Get-PlanText -Budget '8')
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) 'Over budget: schedule totals 9 h'
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Write-Plan $id (Get-PlanText -Budget '10')
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) | Out-Null
}

Write-Section 'plan validation and downstream invalidation'

Test-Case 'plan validation blames the planner: only the plan is retried, then re-validated' {
    $id = New-ResearchedRun
    Complete-Coverage $id
    Complete-Plan $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation')) | Out-Null
    Write-ValidatorReport -RunId $id -Report plan -Findings @(New-Finding 'study-planner' 'Sessions ignore the 1-hour daily limit.' 'blocking' 'requirements_mismatch')
    $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'plan-validation')
    Assert-Equal 'plan' (@($r.Json.retry | ForEach-Object { $_.step }) -join ',')
    $s = Read-RunState $id
    Assert-Equal 'failed' $s.steps.plan.status
    Assert-Equal 'plan-validation' $s.steps.plan.history[-1].gate
    Assert-Equal 'pending' $s.steps.'plan-validation'.status
    Assert-Equal 'passed' $s.steps.coverage.status 'coverage is upstream and untouched'

    Assert-Equal 2 (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan'))).attempt
    Write-Plan $id ((Get-PlanText) + "`nRevised.")
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')) | Out-Null
    Assert-Equal 1 (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation'))).attempt
    Write-ValidatorReport -RunId $id -Report plan
    $v = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan-validation'))
    Assert-Equal 'paused' $v.workflow_status
}

Test-Case 'plan validation blames research: research reopens and coverage, plan, and validation are all invalidated' {
    $id = New-ResearchedRun
    Complete-Coverage $id
    Complete-Plan $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation')) | Out-Null
    Write-ValidatorReport -RunId $id -Report plan -Findings @(New-Finding 'architecture-researcher' 'Claims Service Bus guarantees exactly-once delivery; the cited page says at-least-once.' 'blocking' 'conflicting_findings')
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan-validation'))
    $s = Read-RunState $id
    Assert-Equal 'failed' $s.steps.'research-architecture'.status
    foreach ($name in 'coverage', 'plan', 'plan-validation') {
        Assert-Equal 'pending' $s.steps[$name].status $name
        Assert-Match 'invalidated$' (Get-Results $s.steps[$name]) $name
    }
    Assert-Equal 'passed' $s.steps.'research-data'.status
    Assert-Equal 'passed' $s.steps.'research-dotnet'.status
}

Test-Case 'downstream invalidation: a re-run upstream step resets its dependents; a stale attempt is not counted' {
    $id = New-ResearchedRun
    Complete-Coverage $id
    Complete-Plan $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan-validation')) | Out-Null
    Write-ValidatorReport -RunId $id -Report plan
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan-validation')) | Out-Null

    # A supported change to a passed upstream artifact (here, discarding the data research so
    # its owner re-runs it) invalidates coverage, the plan, and the plan validation.
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id) 'research/data.md') -Value 'Edited.'
    Assert-Ok (Invoke-State @('resolve', '-RunId', $id, '-Step', 'research-data', '-Resolution', 'discard')) | Out-Null
    $s = Read-RunState $id
    foreach ($name in 'coverage', 'plan', 'plan-validation') {
        Assert-Equal 'pending' $s.steps[$name].status $name
        Assert-Match 'passed,invalidated$' (Get-Results $s.steps[$name]) $name
    }
    Assert-Equal 'passed' $s.steps.'research-dotnet'.status

    # The data research re-runs, then coverage is restarted; if the research is re-run again
    # mid-attempt (coverage routed it back), `complete` reports stale and counts nothing.
    Assert-Equal 1 (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data'))).attempt
    Write-Research $id 'data'
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-data')) | Out-Null
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
    Write-ValidatorReport -RunId $id -Report coverage
    $s = Read-RunState $id
    $s.steps.'research-data'.status = 'failed'   # as if another gate had routed a finding to it
    $s | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path (Get-RunDir $id) 'state.json') -Encoding utf8NoBOM
    $c = Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage')
    Assert-Equal 'stale' $c.Json.result
    Assert-Equal 0 (Get-Step $id 'coverage').attempts 'a stale attempt is not counted'
}

Write-Section 'retry exhaustion'

Test-Case 'research blamed by coverage three times exhausts its budget and fails the run' {
    $id = New-ResearchedRun
    foreach ($round in 1..3) {
        if ($round -gt 1) {
            Assert-Equal $round (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data'))).attempt
            Write-Research $id 'data' ((Get-ResearchText -Area data) + "`nRound $round.")
            Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-data')) | Out-Null
        }
        Assert-Equal 1 (Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage'))).attempt "round $round"
        Write-ValidatorReport -RunId $id -Report coverage -Statuses @{ 'EF Core performance' = 'partial' } -Findings @(
            New-Finding 'data-researcher' "Still shallow (round $round)." -Topic 'EF Core performance')
        $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage')
        Assert-Equal (3 - $round) $r.Json.retry[0].attempts_left "round $round"
    }
    Assert-Equal 'failed' $r.Json.workflow_status
    Assert-Equal 'research-data' (@($r.Json.failed_steps) -join ',')
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data')) 'used all 3 attempts'
    Assert-Equal 'passed' (Get-Step $id 'research-dotnet').status
}

Test-Case 'plan failing its gate three times exhausts the plan and fails the run' {
    $id = New-ResearchedRun
    Complete-Coverage $id
    foreach ($n in 1..3) {
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
        Write-Plan $id (Get-PlanText -SessionMinutes 120)
        $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'plan')
        Assert-Fails $r 'Over budget'
    }
    Assert-Equal 'failed' $r.Json.workflow_status
    Assert-Equal 'plan' (@($r.Json.failed_steps) -join ',')
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) 'used all 3 attempts'
    Assert-Equal 'passed' (Get-Step $id 'coverage').status
}

Test-Case 'validator producing three malformed reports exhausts the coverage step' {
    $id = New-ResearchedRun
    foreach ($n in 1..3) {
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'coverage')) | Out-Null
        Set-Content -LiteralPath (Join-Path (Get-RunDir $id) 'validation/coverage.json') -Value '{ not json'
        Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'coverage')) 'not valid JSON'
    }
    $s = Read-RunState $id
    Assert-Equal 'failed' $s.workflow_status
    Assert-Equal 'coverage' (@($s.failed_steps) -join ',')
    Assert-Equal 3 @(Get-ChildItem (Join-Path (Get-RunDir $id) 'validation/history') -Filter 'coverage-attempt*.json').Count 'every attempt archived'
}
