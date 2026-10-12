#Requires -Version 7.0
# Sequential tests for scripts/state.ps1. Dot-sourced by tests/run-tests.ps1, after StateTestKit.ps1.

Write-Section 'init'

Test-Case 'init creates state.json with a pending requirements step' {
    $r = Assert-Ok (Invoke-State @('init', '-Label', 'Senior Backend!'))
    Assert-Match '^\d{8}-\d{6}-senior-backend-[0-9a-f]{6}$' $r.run_id
    $s = Read-RunState $r.run_id
    Assert-Equal 'in_progress' $s.workflow_status
    Assert-Equal 'requirements' $s.current_step
    Assert-Equal 'pending' $s.steps.requirements.status
    Assert-Equal 0 $s.steps.requirements.attempts
    Assert-True ($null -eq $s.research) 'research is null before selection'
    Assert-NoLeftovers $r.run_id
}

Test-Case 'invalid or unknown run ids are rejected' {
    Assert-Fails (Invoke-State @('show', '-RunId', '../escape')) 'Invalid run id'
    Assert-Fails (Invoke-State @('show', '-RunId', 'does-not-exist')) 'No state.json'
}

Test-Case 'unknown step is rejected' {
    $id = New-Run
    Write-ConfirmedInput $id
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'research-nope')) 'Unknown step'
}

Write-Section 'requirements step transitions'

Test-Case 'start requires confirmed-input.md to exist' {
    $id = New-Run
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) 'Missing confirmed input'
    Assert-Equal 0 (Read-RunState $id).steps.requirements.attempts 'a refused start must not consume an attempt'
}

Test-Case 'start marks running, records the input hash, and refuses a second start' {
    $id = New-Run
    Write-ConfirmedInput $id
    $r = Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements'))
    Assert-Equal 1 $r.attempt
    $e = (Read-RunState $id).steps.requirements
    Assert-Equal 'running' $e.status
    Assert-Equal (Get-FileHash (Join-Path (Get-RunDir $id) 'confirmed-input.md') -Algorithm SHA256).Hash.ToLowerInvariant() $e.input_sha256
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) 'already running'
    Assert-Equal 1 (Read-RunState $id).steps.requirements.attempts
}

Test-Case 'complete and fail require a running step' {
    $id = New-Run
    Write-ConfirmedInput $id
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'requirements')) 'not running'
    Assert-Fails (Invoke-State @('fail', '-RunId', $id, '-Step', 'requirements', '-Reason', 'x')) 'not running'
}

Test-Case 'valid requirements pass, record the blocking count, and pause for selection' {
    $id = New-Run
    Write-ConfirmedInput $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    Write-Requirements $id (Get-RequirementsText -Blocking 2)
    $r = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'requirements', '-AgentId', 'agent-1'))
    Assert-Equal 'passed' $r.result
    Assert-Equal 2 $r.blocking_open_questions
    $s = Read-RunState $id
    Assert-Equal 'passed' $s.steps.requirements.status
    Assert-Equal 'agent-1' $s.steps.requirements.agent_id
    Assert-Equal 'paused' $s.workflow_status
    Assert-Equal 'research-selection' $s.next_step
    Assert-Equal (Get-FileHash (Join-Path (Get-RunDir $id) 'requirements.md') -Algorithm SHA256).Hash.ToLowerInvariant() $s.steps.requirements.artifact_sha256
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) 'already passed'
    Assert-NoLeftovers $id
}

Test-Case 'malformed requirements fail the gate with specific problems' {
    $cases = @(
        @{ Name = 'missing artifact'; Text = $null; Pattern = 'Artifact not found' }
        @{ Name = 'empty artifact'; Text = "  `n "; Pattern = 'Artifact is empty' }
        @{ Name = 'missing heading'; Text = (Get-RequirementsText -OmitHeadings '## Knowledge Gaps'); Pattern = "Missing heading: '## Knowledge Gaps'" }
        @{ Name = 'non-numeric blocking count'; Text = (Get-RequirementsText -BlockingValue 'two'); Pattern = 'blocking_open_questions' }
    )
    foreach ($c in $cases) {
        $id = New-Run
        Write-ConfirmedInput $id
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
        if ($null -ne $c.Text) { Write-Requirements $id $c.Text }
        $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'requirements')
        Assert-Fails $r $c.Pattern $c.Name
        Assert-Equal 'failed' $r.Json.result $c.Name
        Assert-Equal 2 $r.Json.attempts_left $c.Name
        $e = (Read-RunState $id).steps.requirements
        Assert-Equal 'failed' $e.status $c.Name
        Assert-Equal 1 @($e.history).Count $c.Name
        Assert-Match $c.Pattern ($e.history[0].reasons -join ' ') $c.Name
    }
}

Test-Case 'requirements retry limit: 3 failed attempts exhaust the step and fail the run' {
    $id = New-Run
    Write-ConfirmedInput $id
    foreach ($n in 1..3) {
        $r = Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements'))
        Assert-Equal $n $r.attempt
        $f = Assert-Ok (Invoke-State @('fail', '-RunId', $id, '-Step', 'requirements', '-Reason', "bad $n"))
        Assert-Equal (3 - $n) $f.attempts_left
    }
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) 'used all 3 attempts'
    $s = Read-RunState $id
    Assert-Equal 3 $s.steps.requirements.attempts
    Assert-Equal 3 @($s.steps.requirements.history).Count
    Assert-Equal 'failed' $s.workflow_status
    Assert-Equal 'requirements' (@($s.failed_steps) -join ',')
}

Test-Case 'a retry after a failed attempt can pass' {
    $id = New-Run
    Write-ConfirmedInput $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    Write-Requirements $id (Get-RequirementsText -OmitHeadings '## Topics')
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'requirements'))
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    Write-Requirements $id
    $r = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'requirements'))
    Assert-Equal 2 $r.attempt
    $h = @((Read-RunState $id).steps.requirements.history)
    Assert-Equal 'failed,passed' (($h | ForEach-Object { $_.result }) -join ',')
}

Test-Case 'changed input: confirmed-input.md edited during the requirements attempt fails as stale' {
    $id = New-Run
    Write-ConfirmedInput $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    Write-ConfirmedInput $id "# Confirmed Requirements`n`nChanged after start."
    Write-Requirements $id
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'requirements')) 'Stale: confirmed-input.md changed'
}

Write-Section 'research selection'

Test-Case 'select is refused before requirements pass' {
    $id = New-Run
    Write-ConfirmedInput $id
    $path = Write-Selection $id (Get-DefaultSelection)
    Assert-Fails (Invoke-State @('select', '-RunId', $id, '-SelectionFile', $path)) 'Requirements step must pass'
}

Test-Case 'invalid selections are rejected without changing state' {
    $id = New-PassedRun
    $before = Get-Content -LiteralPath (Join-Path (Get-RunDir $id) 'state.json') -Raw
    $dup = Get-DefaultSelection
    $dup.selected[1].topics = @('Async internals in .NET')
    $cases = @(
        @{ Name = 'unknown agent'; Sel = @{ selected = @(@{ agent = 'cloud-researcher'; topics = @('Azure'); reason = 'r' }) }; Pattern = "Unknown research agent 'cloud-researcher'" }
        @{ Name = 'agent missing from both lists'; Sel = @{ selected = @(@{ agent = 'data-researcher'; topics = @('EF'); reason = 'r' }); not_selected = @() }; Pattern = "'dotnet-researcher' must appear" }
        @{ Name = 'duplicate topic'; Sel = $dup; Pattern = 'assigned to more than one agent' }
        @{ Name = 'no topics'; Sel = @{ selected = @(@{ agent = 'data-researcher'; topics = @(); reason = 'r' }); not_selected = @(@{ agent = 'dotnet-researcher'; reason = 'r' }, @{ agent = 'architecture-researcher'; reason = 'r' }) }; Pattern = 'needs at least one topic' }
        @{ Name = 'empty reason'; Sel = @{ selected = @(@{ agent = 'data-researcher'; topics = @('EF'); reason = ' ' }); not_selected = @(@{ agent = 'dotnet-researcher'; reason = 'r' }, @{ agent = 'architecture-researcher'; reason = 'r' }) }; Pattern = 'non-empty' }
        @{ Name = 'nothing selected'; Sel = @{ selected = @(); not_selected = @(@{ agent = 'data-researcher'; reason = 'r' }, @{ agent = 'dotnet-researcher'; reason = 'r' }, @{ agent = 'architecture-researcher'; reason = 'r' }) }; Pattern = 'at least one agent' }
    )
    foreach ($c in $cases) {
        $path = Write-Selection $id $c.Sel
        $r = Invoke-State @('select', '-RunId', $id, '-SelectionFile', $path)
        Assert-Fails $r $c.Pattern $c.Name
        Assert-Equal 'invalid' $r.Json.result $c.Name
    }
    $after = Get-Content -LiteralPath (Join-Path (Get-RunDir $id) 'state.json') -Raw
    Assert-Equal $before $after 'state.json must be unchanged by invalid selections'
    Assert-NoLeftovers $id
}

Test-Case 'valid selection creates one pending step per selected agent, and only once' {
    $id = New-PassedRun -Areas @('dotnet', 'architecture')
    $path = Write-Selection $id (Get-DefaultSelection @('dotnet', 'architecture'))
    $r = Assert-Ok (Invoke-State @('select', '-RunId', $id, '-SelectionFile', $path))
    Assert-Equal 'data-researcher' (@($r.skipped) -join ',')
    $s = Read-RunState $id
    Assert-Equal 'requirements,research-dotnet,research-architecture,coverage,plan,plan-validation' (@($s.steps.Keys) -join ',')
    Assert-Equal 'async internals,concurrency,system design' (@($s.research.coverage | ForEach-Object { $_.mandatory_topic }) -join ',')
    Assert-Equal 'Async internals in .NET|Concurrency in .NET' (@($s.steps.'research-dotnet'.topics) -join '|')
    Assert-Equal 'pending' $s.steps.'research-dotnet'.status
    Assert-Equal 2 @($s.research.selected_agents).Count
    Assert-Equal 'data-researcher' $s.research.not_selected[0].agent
    Assert-Equal 'in_progress' $s.workflow_status
    Assert-Fails (Invoke-State @('select', '-RunId', $id, '-SelectionFile', $path)) 'already selected'
}

Write-Section 'research gate'

Test-Case 'valid research artifacts pass and record the source count' {
    $id = New-SelectedRun
    foreach ($area in 'dotnet', 'data', 'architecture') {
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', "research-$area")) | Out-Null
        Write-Research $id $area
        $r = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', "research-$area", '-AgentId', "agent-$area"))
        Assert-Equal 3 $r.source_count "$area"
    }
    $s = Read-RunState $id
    Assert-Equal 'in_progress' $s.workflow_status
    Assert-Equal 'coverage' $s.current_step
    Assert-Equal 0 @($s.failed_steps).Count
    Assert-NoLeftovers $id
}

Test-Case 'malformed research artifacts fail with specific problems' {
    $cases = @(
        @{ Name = 'missing Sources heading'; Text = (Get-ResearchText -Area data -OmitHeadings '## Sources'); Pattern = "Missing heading: '## Sources'" }
        @{ Name = 'missing Interview Questions'; Text = (Get-ResearchText -Area data -OmitHeadings '## Interview Questions'); Pattern = "Missing heading: '## Interview Questions'" }
        @{ Name = 'wrong generated_by'; Text = (Get-ResearchText -Area data -GeneratedBy 'dotnet-researcher'); Pattern = "generated_by: data-researcher" }
        @{ Name = 'assigned topic missing'; Text = (Get-ResearchText -Area data -Topics @('Something else')); Pattern = "missing heading '### EF Core performance'" }
        @{ Name = 'missing title'; Text = ((Get-ResearchText -Area data) -replace '# Research: data', '# Notes'); Pattern = 'Missing title heading' }
    )
    foreach ($c in $cases) {
        $id = New-SelectedRun @('data')
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data')) | Out-Null
        Write-Research $id 'data' $c.Text
        Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-data')) $c.Pattern $c.Name
        Assert-Equal 'failed' (Read-RunState $id).steps.'research-data'.status $c.Name
    }
}

Test-Case 'source requirements: at least 3 distinct URLs, counted only under ## Sources' {
    $id = New-SelectedRun @('architecture')
    # Duplicates count once; the inline Findings URL does not count.
    $text = Get-ResearchText -Area architecture -Sources @('https://martinfowler.com/a', 'https://martinfowler.com/a', 'https://microservices.io/b')
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-architecture')) | Out-Null
    Write-Research $id 'architecture' $text
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-architecture')) "lists 2 distinct URL\(s\); at least 3"
}

Test-Case 'source requirements: Microsoft Learn URL required for dotnet and data, not architecture' {
    $nonMs = @('https://martinfowler.com/a', 'https://microservices.io/b', 'https://github.com/c')
    foreach ($area in 'dotnet', 'data') {
        $id = New-SelectedRun @($area)
        Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', "research-$area")) | Out-Null
        Write-Research $id $area (Get-ResearchText -Area $area -Sources $nonMs)
        Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', "research-$area")) 'no Microsoft Learn URL' $area
    }
    $id = New-SelectedRun @('architecture')
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-architecture')) | Out-Null
    Write-Research $id 'architecture' (Get-ResearchText -Area architecture -Sources $nonMs)
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-architecture')) | Out-Null
}

Write-Section 'changed input hashes'

Test-Case 'research start is refused when requirements.md changed after it passed' {
    $id = New-SelectedRun @('data')
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id) 'requirements.md') -Value 'edited'
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data')) 'requirements.md changed after it passed'
    Assert-Equal 0 (Read-RunState $id).steps.'research-data'.attempts
}

Test-Case 'research start is refused when confirmed-input.md changed after requirements were built' {
    $id = New-SelectedRun @('data')
    Write-ConfirmedInput $id "# Confirmed Requirements`n`nAnswered a question later."
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data')) 'confirmed-input.md changed'
}

Test-Case 'research start records input hashes for confirmed input, requirements, and assignment' {
    $id = New-SelectedRun @('data')
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data')) | Out-Null
    $s = Read-RunState $id
    $h = $s.steps.'research-data'.inputs_sha256
    Assert-Equal $s.steps.requirements.artifact_sha256 $h.requirements
    Assert-Equal $s.steps.requirements.input_sha256 $h.confirmed_input
    Assert-Match '^[0-9a-f]{64}$' $h.assignment
}

Test-Case 'research complete fails as stale when requirements.md or confirmed-input.md changes mid-attempt' {
    $id = New-SelectedRun @('data', 'architecture')
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data')) | Out-Null
    Write-Research $id 'data'
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id) 'requirements.md') -Value 'edited'
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-data')) 'Stale: requirements.md changed'

    $id = New-SelectedRun @('architecture')
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-architecture')) | Out-Null
    Write-Research $id 'architecture'
    Write-ConfirmedInput $id 'changed'
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-architecture')) 'Stale: confirmed-input.md changed'
}

Write-Section 'research failures are isolated'

Test-Case 'fail -NoRetry blocks retries immediately and fails the run once others finish' {
    $id = New-SelectedRun @('dotnet', 'data')
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-dotnet')) | Out-Null
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data')) | Out-Null
    $f = Assert-Ok (Invoke-State @('fail', '-RunId', $id, '-Step', 'research-dotnet', '-NoRetry', '-Reason', 'FAILED: TOOLS_UNAVAILABLE'))
    Assert-Equal 0 $f.attempts_left
    Assert-Equal 'in_progress' $f.workflow_status 'data is still running'
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'research-dotnet')) 'non-retryable'
    Write-Research $id 'data'
    $c = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-data'))
    Assert-Equal 'failed' $c.workflow_status
    $s = Read-RunState $id
    Assert-Equal 'research-dotnet' (@($s.failed_steps) -join ',')
    Assert-Equal 'passed' $s.steps.'research-data'.status
    Assert-Equal 1 $s.steps.'research-dotnet'.attempts
}

Test-Case 'one agent exhausting its retries leaves the other steps and artifacts untouched' {
    $id = New-SelectedRun
    foreach ($area in 'dotnet', 'data', 'architecture') { Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', "research-$area")) | Out-Null }
    Write-Research $id 'dotnet'
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-dotnet', '-AgentId', 'a-dotnet')) | Out-Null
    $dotnetBefore = (Read-RunState $id).steps.'research-dotnet' | ConvertTo-Json -Depth 10
    $dotnetFileHash = (Get-FileHash (Join-Path (Get-RunDir $id) 'research/dotnet.md') -Algorithm SHA256).Hash

    # data fails three times, while architecture is still running.
    foreach ($n in 1..3) {
        if ($n -gt 1) { Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data')) | Out-Null }
        Write-Research $id 'data' (Get-ResearchText -Area data -Sources @('https://learn.microsoft.com/only-one'))
        $r = Invoke-State @('complete', '-RunId', $id, '-Step', 'research-data')
        Assert-Fails $r 'at least 3'
        Assert-Equal 'in_progress' $r.Json.workflow_status "attempt ${n}: architecture still running"
        Assert-Equal 'running' (Read-RunState $id).steps.'research-architecture'.status "attempt $n"
    }
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'research-data')) 'used all 3 attempts'

    Write-Research $id 'architecture'
    $c = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-architecture'))
    Assert-Equal 'failed' $c.workflow_status
    $s = Read-RunState $id
    Assert-Equal 'research-data' (@($s.failed_steps) -join ',')
    Assert-Equal 'passed' $s.steps.'research-architecture'.status
    Assert-Equal 1 $s.steps.'research-architecture'.attempts
    Assert-Equal $dotnetBefore ($s.steps.'research-dotnet' | ConvertTo-Json -Depth 10) 'passed dotnet step must not change'
    Assert-Equal $dotnetFileHash (Get-FileHash (Join-Path (Get-RunDir $id) 'research/dotnet.md') -Algorithm SHA256).Hash
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'research-dotnet')) 'already passed'
}

Test-Case 'a failed step with attempts left keeps the run in progress' {
    $id = New-SelectedRun @('dotnet', 'data')
    foreach ($area in 'dotnet', 'data') { Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', "research-$area")) | Out-Null }
    Write-Research $id 'dotnet'
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-dotnet')) | Out-Null
    $f = Assert-Ok (Invoke-State @('fail', '-RunId', $id, '-Step', 'research-data', '-Reason', 'agent error'))
    Assert-Equal 2 $f.attempts_left
    Assert-Equal 'in_progress' $f.workflow_status
    Assert-Equal 0 @((Read-RunState $id).failed_steps).Count
}

Write-Section 'locking (single process)'

Test-Case 'in-process invocation releases the lock on success, error, and exit 1' {
    $id = New-PassedRun
    $lock = Join-Path (Get-RunDir $id) 'state.lock'
    $bad = Write-Selection $id @{ selected = @() }
    $global:LASTEXITCODE = 0
    & $script:StateScript select -RunId $id -SelectionFile $bad -RunsRoot $script:RunsRoot | Out-Null
    Assert-Equal 1 $LASTEXITCODE 'invalid selection exits 1'
    Assert-True (-not (Test-Path $lock)) 'lock released after exit 1'
    try { & $script:StateScript start -RunId $id -Step research-data -RunsRoot $script:RunsRoot | Out-Null; throw 'expected throw' }
    catch { Assert-Match 'Unknown step' $_.Exception.Message }
    Assert-True (-not (Test-Path $lock)) 'lock released after a throw'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $script:StateScript select -RunId $id -SelectionFile (Write-Selection $id (Get-DefaultSelection)) -RunsRoot $script:RunsRoot | Out-Null
    Assert-True ($sw.Elapsed.TotalSeconds -lt 5) "third in-process call must not wait for a leaked lock ($($sw.Elapsed.TotalSeconds)s)"
    Assert-NoLeftovers $id
}

Test-Case 'a stale state.lock file with no open handle does not block and is removed' {
    $id = New-Run
    Write-ConfirmedInput $id
    Set-Content -LiteralPath (Join-Path (Get-RunDir $id) 'state.lock') -Value 'left over'
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    Assert-NoLeftovers $id
}
