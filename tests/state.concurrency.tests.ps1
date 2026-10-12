#Requires -Version 7.0
# Concurrency tests for scripts/state.ps1, using real concurrent pwsh processes.
# Dot-sourced by tests/run-tests.ps1 (uses $Iterations from the runner).

Write-Section "concurrency (real processes, $Iterations iterations per scenario)"

# Shared checks after every concurrent batch.
function Assert-BatchHealthy($Batch, [string]$RunId, [string]$Label) {
    foreach ($r in $Batch.Results) {
        Assert-True $r.json_valid "${Label}: state.json invalid right after pid $($r.pid) $($r.action) $($r.step): $($r.json_error)"
        if ($r.exit_code -ne 0) {
            Assert-True ($r.error -notmatch 'Timed out|being used by another process|Access to the path') "${Label}: infrastructure error: $($r.error)"
        }
    }
    foreach ($rd in $Batch.Readers) {
        Assert-Equal 0 $rd.parse_errors "${Label}: concurrent reader saw invalid JSON: $($rd.samples -join ' | ')"
    }
    Assert-StateJsonValid $RunId
    Assert-NoLeftovers $RunId
}

$script:OverlapStats = [System.Collections.Generic.List[object]]::new()
function Add-Overlap($Batch) { $o = Get-Overlap $Batch.Results; $script:OverlapStats.Add($o); return $o }

Test-Case "same-step start race: 8 processes, exactly one wins (x$Iterations)" {
    for ($n = 1; $n -le $Iterations; $n++) {
        $id = New-Run
        Write-ConfirmedInput $id
        $ops = 1..8 | ForEach-Object { @{ Action = 'start'; RunId = $id; Step = 'requirements' } }
        $b = Invoke-Concurrent -Operations $ops
        Add-Overlap $b | Out-Null
        $winners = @($b.Results | Where-Object { $_.exit_code -eq 0 })
        Assert-Equal 1 $winners.Count "iteration $n winners"
        foreach ($l in $b.Results | Where-Object { $_.exit_code -ne 0 }) { Assert-Match 'already running' $l.error "iteration $n loser" }
        $e = (Read-RunState $id).steps.requirements
        Assert-Equal 1 $e.attempts "iteration $n attempts"
        Assert-Equal 'running' $e.status
        Assert-BatchHealthy $b $id "iteration $n"
    }
}

Test-Case "12-process storm across 3 research steps: one winner per step, no lost updates (x$Iterations)" {
    for ($n = 1; $n -le $Iterations; $n++) {
        $id = New-SelectedRun
        $ops = foreach ($area in 'dotnet', 'data', 'architecture') { 1..4 | ForEach-Object { @{ Action = 'start'; RunId = $id; Step = "research-$area" } } }
        $b = Invoke-Concurrent -Operations $ops
        Add-Overlap $b | Out-Null
        $s = Read-RunState $id
        foreach ($area in 'dotnet', 'data', 'architecture') {
            $wins = @($b.Results | Where-Object { $_.step -eq "research-$area" -and $_.exit_code -eq 0 })
            Assert-Equal 1 $wins.Count "iteration $n $area winners"
            Assert-Equal 'running' $s.steps."research-$area".status "iteration $n $area status (lost update?)"
            Assert-Equal 1 $s.steps."research-$area".attempts "iteration $n $area attempts"
            Assert-Match '^[0-9a-f]{64}$' $s.steps."research-$area".inputs_sha256.requirements
        }
        Assert-Equal 'in_progress' $s.workflow_status
        Assert-BatchHealthy $b $id "iteration $n"
    }
}

Test-Case "parallel research lifecycle: 3 concurrent starts then 3 concurrent completes (x$Iterations)" {
    for ($n = 1; $n -le $Iterations; $n++) {
        $id = New-SelectedRun
        foreach ($area in 'dotnet', 'data', 'architecture') { Write-Research $id $area }
        $starts = foreach ($area in 'dotnet', 'data', 'architecture') { @{ Action = 'start'; RunId = $id; Step = "research-$area" } }
        $b1 = Invoke-Concurrent -Operations $starts
        Add-Overlap $b1 | Out-Null
        Assert-Equal 3 @($b1.Results | Where-Object { $_.exit_code -eq 0 }).Count "iteration $n starts"
        Assert-BatchHealthy $b1 $id "iteration $n starts"

        $completes = foreach ($area in 'dotnet', 'data', 'architecture') { @{ Action = 'complete'; RunId = $id; Step = "research-$area"; AgentId = "agent-$area-$n" } }
        $b2 = Invoke-Concurrent -Operations $completes
        Add-Overlap $b2 | Out-Null
        foreach ($r in $b2.Results) { Assert-Equal 0 $r.exit_code "iteration $n complete $($r.step): $($r.error) $($r.output)" }
        $s = Read-RunState $id
        foreach ($area in 'dotnet', 'data', 'architecture') {
            $e = $s.steps."research-$area"
            Assert-Equal 'passed' $e.status "iteration $n $area (lost update?)"
            Assert-Equal "agent-$area-$n" $e.agent_id "iteration $n $area agent_id"
            Assert-Equal 1 @($e.history).Count "iteration $n $area history"
            Assert-Equal 3 $e.source_count
        }
        Assert-Equal 'coverage' $s.current_step "iteration ${n}: next step is the coverage gate"
        Assert-BatchHealthy $b2 $id "iteration $n completes"
    }
}

Test-Case "mixed concurrent outcomes and retries stay isolated (x$Iterations)" {
    for ($n = 1; $n -le $Iterations; $n++) {
        $id = New-SelectedRun
        foreach ($area in 'dotnet', 'data', 'architecture') { Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', "research-$area")) | Out-Null }
        Write-Research $id 'dotnet'
        Write-Research $id 'data' (Get-ResearchText -Area data -Sources @('https://learn.microsoft.com/one'))
        $ops = @(
            @{ Action = 'complete'; RunId = $id; Step = 'research-dotnet'; AgentId = 'a1' }   # passes
            @{ Action = 'complete'; RunId = $id; Step = 'research-data'; AgentId = 'a2' }     # gate failure
            @{ Action = 'fail'; RunId = $id; Step = 'research-architecture'; Reason = 'FAILED: TOOLS_UNAVAILABLE'; NoRetry = $true }
        )
        $b = Invoke-Concurrent -Operations $ops
        Add-Overlap $b | Out-Null
        Assert-BatchHealthy $b $id "iteration $n round 1"
        $s = Read-RunState $id
        Assert-Equal 'passed' $s.steps.'research-dotnet'.status "iteration $n dotnet"
        Assert-Equal 'failed' $s.steps.'research-data'.status "iteration $n data"
        Assert-Equal 'failed' $s.steps.'research-architecture'.status "iteration $n architecture"
        Assert-True $s.steps.'research-architecture'.retry_blocked "iteration $n retry_blocked"
        Assert-Equal 'in_progress' $s.workflow_status "iteration ${n}: data can still retry"

        # Round 2: retry data concurrently with a refused architecture retry.
        Write-Research $id 'data'
        $b2 = Invoke-Concurrent -Operations @(
            @{ Action = 'start'; RunId = $id; Step = 'research-data' }
            @{ Action = 'start'; RunId = $id; Step = 'research-architecture' }
            @{ Action = 'start'; RunId = $id; Step = 'research-dotnet' }
        )
        Add-Overlap $b2 | Out-Null
        Assert-BatchHealthy $b2 $id "iteration $n round 2"
        Assert-Equal 'research-data' (@($b2.Results | Where-Object { $_.exit_code -eq 0 } | ForEach-Object { $_.step }) -join ',') "iteration $n round 2 winners"
        Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'research-data')) | Out-Null
        $s = Read-RunState $id
        Assert-Equal 2 $s.steps.'research-data'.attempts
        Assert-Equal 'failed,passed' (($s.steps.'research-data'.history | ForEach-Object { $_.result }) -join ',')
        Assert-Equal 1 @($s.steps.'research-dotnet'.history).Count
        Assert-Equal 'failed' $s.workflow_status
        Assert-Equal 'research-architecture' (@($s.failed_steps) -join ',')
    }
}

Test-Case "attempt accounting under contention: 3 concurrent start/fail rounds exhaust every step exactly (x$Iterations)" {
    for ($n = 1; $n -le $Iterations; $n++) {
        $id = New-SelectedRun
        foreach ($round in 1..3) {
            foreach ($action in 'start', 'fail') {
                $ops = foreach ($area in 'dotnet', 'data', 'architecture') {
                    $op = @{ Action = $action; RunId = $id; Step = "research-$area" }
                    if ($action -eq 'fail') { $op.Reason = "round $round" }
                    $op
                }
                $b = Invoke-Concurrent -Operations $ops
                Add-Overlap $b | Out-Null
                foreach ($r in $b.Results) { Assert-Equal 0 $r.exit_code "iteration $n round $round $action $($r.step): $($r.error)" }
                Assert-BatchHealthy $b $id "iteration $n round $round $action"
            }
        }
        $s = Read-RunState $id
        foreach ($area in 'dotnet', 'data', 'architecture') {
            $e = $s.steps."research-$area"
            Assert-Equal 3 $e.attempts "iteration $n $area attempts"
            Assert-Equal 3 @($e.history).Count "iteration $n $area history (lost update?)"
            Assert-Equal 'round 1|round 2|round 3' (($e.history | ForEach-Object { $_.reasons -join '' }) -join '|') "iteration $n $area history order"
        }
        Assert-Equal 'failed' $s.workflow_status
        Assert-Equal 3 @($s.failed_steps).Count
    }
}

Test-Case "unlocked readers never see invalid JSON while writers run (x$Iterations)" {
    $totalReads = 0; $ioErrors = 0
    for ($n = 1; $n -le $Iterations; $n++) {
        $id = New-SelectedRun
        foreach ($area in 'dotnet', 'data', 'architecture') { Write-Research $id $area }
        $starts = foreach ($area in 'dotnet', 'data', 'architecture') { @{ Action = 'start'; RunId = $id; Step = "research-$area" } }
        $b = Invoke-Concurrent -Operations $starts -Readers 2
        foreach ($r in $b.Results) { Assert-Equal 0 $r.exit_code "iteration $n writer $($r.step) failed with readers present: $($r.error)" }
        Assert-BatchHealthy $b $id "iteration $n"
        $totalReads += ($b.Readers | Measure-Object reads -Sum).Sum
        $ioErrors += ($b.Readers | Measure-Object io_errors -Sum).Sum
    }
    Add-Note "readers parsed state.json $totalReads times with 0 invalid reads; $ioErrors transient read sharing errors"
}

Test-Case 'a held lock makes state.ps1 wait, then proceed' {
    $id = New-Run
    Write-ConfirmedInput $id
    $ready = Join-Path $script:TestRoot "holder-ready-$id"
    $holder = Start-PwshProcess (Join-Path $PSScriptRoot 'helpers/hold-lock.ps1') @('-LockPath', (Join-Path (Get-RunDir $id) 'state.lock'), '-HoldMs', '3000', '-ReadyFile', $ready)
    while (-not (Test-Path $ready)) { Start-Sleep -Milliseconds 20 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    $waited = $sw.Elapsed.TotalSeconds
    $holder.WaitForExit()
    Assert-True ($waited -ge 1.5) "expected to wait for the holder, waited $waited s"
    Assert-Equal 1 (Read-RunState $id).steps.requirements.attempts
    Assert-NoLeftovers $id
    Add-Note ("waited {0:N1}s for a 3s lock holder" -f $waited)
}

Test-Case 'lock timeout leaves state unchanged; a killed holder leaves no orphaned lock' {
    $id = New-Run
    Write-ConfirmedInput $id
    $before = Get-Content -LiteralPath (Join-Path (Get-RunDir $id) 'state.json') -Raw
    $ready = Join-Path $script:TestRoot "holder-ready-$id"
    $lockPath = Join-Path (Get-RunDir $id) 'state.lock'
    $holder = Start-PwshProcess (Join-Path $PSScriptRoot 'helpers/hold-lock.ps1') @('-LockPath', $lockPath, '-HoldMs', '120000', '-ReadyFile', $ready)
    while (-not (Test-Path $ready)) { Start-Sleep -Milliseconds 20 }
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) 'Timed out waiting for state lock'
    Assert-Equal $before (Get-Content -LiteralPath (Join-Path (Get-RunDir $id) 'state.json') -Raw) 'state must be unchanged after a lock timeout'
    $holder.Kill()
    $holder.WaitForExit()
    $deadline = (Get-Date).AddSeconds(5)
    while ((Test-Path $lockPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert-True (-not (Test-Path $lockPath)) 'the OS must remove state.lock when the killed holder''s handle closes'
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    Assert-NoLeftovers $id
}

if ($script:OverlapStats.Count) {
    $all = @($script:OverlapStats | Where-Object AllOverlap).Count
    $spread = $script:OverlapStats | Measure-Object StartSpreadMs -Average -Maximum
    Add-Note ("{0} concurrent batches; in {1} every operation overlapped every other; start spread avg {2:N0} ms, max {3:N0} ms" -f $script:OverlapStats.Count, $all, $spread.Average, $spread.Maximum)
}
