#Requires -Version 7.0
# Phase 4A tests: the deterministic approval state machine. A decision is applied only from
# valid, unconsumed ledger evidence bound to the SHA-256 of the current validated plan.
# Dot-sourced by tests/run-tests.ps1 after state.revision.tests.ps1 (New-ValidatedRun,
# Invoke-Revise, Complete-RevisionCycle, Get-FileSha). Agent outputs are fixtures.

function Get-TextSha([string]$Text) {
    $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($Text))
    try { (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant() } finally { $stream.Dispose() }
}

function Get-LedgerFile([string]$RunId) { Join-Path (Get-RunDir $RunId) 'approval/decisions.jsonl' }

function Get-LedgerLines([string]$RunId) {
    $path = Get-LedgerFile $RunId
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    @([System.IO.File]::ReadAllText($path) -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne '' })
}

function Add-LedgerLine([string]$RunId, [string]$Line) {
    $path = Get-LedgerFile $RunId
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    [System.IO.File]::AppendAllText($path, "$Line`n", [System.Text.UTF8Encoding]::new($false))
}

# TEST-ONLY evidence writer. It stands in for the Phase 4B UserPromptSubmit hook, which will be
# the only production writer of the ledger. state.ps1 deliberately has no command that writes
# ledger entries, so nothing in production can manufacture a user decision this way.
# Defaults produce a valid, correctly chained entry for the current plan; -Override replaces
# (or, with $null, removes) fields to forge invalid evidence.
function Add-TestOnlyLedgerEntry {
    param(
        [string]$RunId,
        [ValidateSet('approve', 'reject', 'request_changes')][string]$Decision = 'approve',
        [string]$PlanSha,
        [int]$PlanVersion,
        [string]$Feedback,
        [string]$PromptId = "prompt-$([guid]::NewGuid().ToString('N').Substring(0, 8))",
        [hashtable]$Override = @{}
    )
    $lines = @(Get-LedgerLines $RunId)
    $seq = $lines.Count + 1
    if (-not $PlanSha) { $PlanSha = Get-FileSha $RunId 'plan.md' }
    if (-not $PlanVersion) { $PlanVersion = (Read-RunState $RunId).steps.plan.version }
    $prompt = switch ($Decision) {
        'approve' { "APPROVE PLAN $RunId $($PlanSha.Substring(0, 12))" }
        'reject' { "REJECT PLAN $RunId" }
        'request_changes' { "REVISE PLAN $RunId $($PlanSha.Substring(0, 12)): $Feedback" }
    }
    $entry = [ordered]@{
        schema        = 1
        seq           = $seq
        decision_id   = 'dec-{0:000}' -f $seq
        prev_sha256   = $(if ($lines.Count) { Get-TextSha $lines[-1] } else { '0' * 64 })
        run_id        = $RunId
        decision      = $Decision
        plan_sha256   = $PlanSha
        plan_version  = $PlanVersion
        prompt_sha256 = Get-TextSha $prompt
        prompt_id     = $PromptId
        session_id    = 'test-session'
        recorded_at   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        source        = 'user-prompt-submit'
    }
    if ($Decision -eq 'request_changes') { $entry.feedback = $Feedback }
    foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $entry.Remove($k) } else { $entry[$k] = $Override[$k] } }
    Add-LedgerLine $RunId ($entry | ConvertTo-Json -Compress)
    return $entry
}

function Invoke-Decide([string]$RunId) { Invoke-State @('decide', '-RunId', $RunId) }

function Write-Guide([string]$RunId, [string]$PlanSha) {
    $html = "<!doctype html><html><head><meta charset=`"utf-8`"><meta name=`"plan-sha256`" content=`"$PlanSha`"><title>Guide</title></head><body>Guide</body></html>"
    Set-Content -LiteralPath (Join-Path (Get-RunDir $RunId) 'guide.html') -Value $html -Encoding utf8NoBOM -NoNewline
}

function New-ApprovedRun {
    $id = New-ValidatedRun
    Add-TestOnlyLedgerEntry $id 'approve' | Out-Null
    Assert-Equal 'approved' (Assert-Ok (Invoke-Decide $id)).result
    return $id
}

# A hand-written approval.json that looks exactly like a real one for the current plan.
function Write-ForgedApproval([string]$RunId) {
    $s = Read-RunState $RunId
    [ordered]@{
        schema = 1; run_id = $RunId; decision = 'approved'; decision_id = 'dec-001'; ledger_seq = 1
        ledger_entry_sha256 = ('a' * 64); plan_sha256 = (Get-FileSha $RunId 'plan.md'); plan_version = $s.steps.plan.version
        plan_validation_sha256 = $s.steps.'plan-validation'.artifact_sha256; decided_at = '2026-10-12T00:00:00Z'; recorded_by = 'state.ps1 decide'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Get-RunDir $RunId) 'approval.json') -Encoding utf8NoBOM
}

Write-Section 'human approval (Phase 4A)'

Test-Case 'a validated plan awaits the user; without ledger evidence nothing approves it, not even a forged approval.json or state.json' {
    $id = New-ValidatedRun
    $s = Read-RunState $id
    Assert-Equal 'awaiting_decision' $s.steps.approval.status
    Assert-Equal 'awaiting_approval' $s.workflow_status
    Assert-Equal 'approval' $s.current_step
    Assert-Equal 'pending' $s.steps.render.status
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'approval')) 'Only the user decides'
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) 'Render refused'

    $r = Invoke-Decide $id
    Assert-Fails $r 'No decision evidence'
    Assert-Equal $false $r.Json.consumed

    # A model-written approval.json is not evidence.
    Write-ForgedApproval $id
    Assert-Fails (Invoke-Decide $id) 'No decision evidence'
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) "Approval is 'awaiting_decision'"

    # Neither is a state.json edited to agree with it: no consumed ledger entry backs it.
    $raw = Read-RunState $id
    $a = $raw.steps.approval
    $doc = Get-Content -LiteralPath (Join-Path (Get-RunDir $id) 'approval.json') -Raw | ConvertFrom-Json -AsHashtable
    $a.status = 'approved'; $a.decision = 'approved'; $a.decision_id = 'dec-001'; $a.ledger_seq = 1; $a.ledger_entry_sha256 = $doc.ledger_entry_sha256
    $a.plan_sha256 = $doc.plan_sha256; $a.plan_version = $doc.plan_version; $a.plan_validation_sha256 = $doc.plan_validation_sha256
    $a.artifact_sha256 = Get-FileSha $id 'approval.json'
    $raw | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path (Get-RunDir $id) 'state.json') -Encoding utf8NoBOM
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) 'No consumed ledger entry backs this approval'
    Assert-Equal 'pending' (Read-RunState $id).steps.render.status
    Assert-NoLeftovers $id
}

Test-Case 'approve: valid evidence approves exactly the current plan; render needs that approval and the approved hash' {
    $id = New-ValidatedRun
    $planSha = Get-FileSha $id 'plan.md'
    $e = Add-TestOnlyLedgerEntry $id 'approve'
    $r = Assert-Ok (Invoke-Decide $id)
    Assert-Equal 'approved' $r.result
    Assert-Equal 'dec-001' $r.decision_id
    Assert-Equal $planSha $r.plan_sha256
    Assert-Equal 'approved' $r.workflow_status
    Assert-Equal 'render (not implemented yet)' $r.next_step
    Assert-Equal 0 $r.remaining_unconsumed

    $s = Read-RunState $id
    $a = $s.steps.approval
    Assert-Equal 'approved' $a.status
    Assert-Equal 1 $a.consumed_through
    Assert-Equal $planSha $a.plan_sha256
    Assert-Equal (Get-TextSha @(Get-LedgerLines $id)[0]) $a.ledger_entry_sha256
    Assert-Equal 'applied' $a.decisions[0].outcome
    $doc = Get-Content -LiteralPath (Join-Path (Get-RunDir $id) 'approval.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-Equal 'approved' $doc.decision
    Assert-Equal $planSha $doc.plan_sha256
    Assert-Equal $a.ledger_entry_sha256 $doc.ledger_entry_sha256
    Assert-Equal $s.steps.'plan-validation'.artifact_sha256 $doc.plan_validation_sha256
    Assert-Equal $a.artifact_sha256 (Get-FileSha $id 'versions/approval-v1.json') 'the approval is snapshotted like an accepted version'

    Assert-Fails (Invoke-Decide $id) 'No unconsumed decision evidence'

    $st = Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'render'))
    Assert-Equal $planSha $st.plan_sha256
    Write-Guide $id ('b' * 64)
    Assert-Fails (Invoke-State @('complete', '-RunId', $id, '-Step', 'render')) 'not the approved plan'
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) | Out-Null
    Write-Guide $id $planSha
    $c = Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'render'))
    Assert-Equal 'passed' $c.result
    Assert-Equal 'completed' $c.workflow_status
    Assert-NoLeftovers $id
}

Test-Case 'forged or malformed evidence is refused and never consumed' {
    $id = New-ValidatedRun
    $good = @{}
    $cases = @(
        @{ Name = 'test-fixture source'; Override = @{ source = 'test-fixture' }; Pattern = "'source' must be 'user-prompt-submit'" }
        @{ Name = 'coordinator source'; Override = @{ source = 'coordinator' }; Pattern = "'source' must be" }
        @{ Name = 'no source'; Override = @{ source = $null }; Pattern = "'source' must be" }
        @{ Name = 'other run'; Override = @{ run_id = 'another-run' }; Pattern = "'run_id' must be" }
        @{ Name = 'broken chain'; Override = @{ prev_sha256 = ('c' * 64) }; Pattern = 'chain is broken' }
        @{ Name = 'seq gap'; Override = @{ seq = 2 }; Pattern = "'seq' must be 1" }
        @{ Name = 'decision id'; Override = @{ decision_id = 'dec-007' }; Pattern = "'decision_id' must be dec-001" }
        @{ Name = 'unknown decision'; Override = @{ decision = 'approved' }; Pattern = "'decision' must be one of" }
        @{ Name = 'short hash'; Override = @{ plan_sha256 = 'abc123def456' }; Pattern = "'plan_sha256' must be 64" }
        @{ Name = 'uppercase hash'; Override = @{ plan_sha256 = ('A' * 64) }; Pattern = "'plan_sha256' must be 64" }
        @{ Name = 'no prompt id'; Override = @{ prompt_id = $null }; Pattern = "'prompt_id' is required" }
        @{ Name = 'approve with feedback'; Override = @{ feedback = 'sneaky' }; Pattern = "only a request_changes decision carries 'feedback'" }
        @{ Name = 'schema'; Override = @{ schema = 2 }; Pattern = "'schema' must be 1" }
    )
    foreach ($c in $cases) {
        Remove-Item -LiteralPath (Get-LedgerFile $id) -Force -ErrorAction SilentlyContinue
        Add-TestOnlyLedgerEntry $id 'approve' -Override $c.Override | Out-Null
        $r = Invoke-Decide $id
        Assert-Fails $r $c.Pattern $c.Name
        Assert-Match 'ledger is invalid' $r.Stdout $c.Name
        Assert-Equal $false $r.Json.consumed $c.Name
    }
    foreach ($bad in @('not json', '[1,2,3]')) {
        Remove-Item -LiteralPath (Get-LedgerFile $id) -Force
        Add-LedgerLine $id $bad
        Assert-Fails (Invoke-Decide $id) 'is not a JSON object' $bad
    }
    Remove-Item -LiteralPath (Get-LedgerFile $id) -Force
    Add-TestOnlyLedgerEntry $id 'request_changes' -Feedback ' ' | Out-Null
    Assert-Fails (Invoke-Decide $id) "must carry the user's 'feedback'"

    # A valid entry followed by a broken one: the whole ledger is untrusted, nothing is consumed.
    Remove-Item -LiteralPath (Get-LedgerFile $id) -Force
    Add-TestOnlyLedgerEntry $id 'approve' | Out-Null
    Add-TestOnlyLedgerEntry $id 'approve' -Override @{ prev_sha256 = ('d' * 64) } | Out-Null
    Assert-Fails (Invoke-Decide $id) 'line 2: .prev_sha256. does not match'

    $s = Read-RunState $id
    Assert-Equal 'awaiting_decision' $s.steps.approval.status
    Assert-Equal 0 $s.steps.approval.consumed_through
    Assert-Equal 0 @($s.steps.approval.decisions).Count
    Assert-True (-not (Test-Path (Join-Path (Get-RunDir $id) 'approval.json'))) 'no approval.json was written'
}

Test-Case 'stale evidence (another plan hash or version, or a plan not yet validated) is consumed and refused' {
    $id = New-ValidatedRun
    $v1 = Get-FileSha $id 'plan.md'
    Assert-Ok (Invoke-Revise $id) | Out-Null
    Complete-RevisionCycle $id 'v2' | Out-Null
    $v2 = Get-FileSha $id 'plan.md'
    Assert-Equal 'awaiting_decision' (Read-RunState $id).steps.approval.status

    Add-TestOnlyLedgerEntry $id 'approve' -PlanSha $v1 -PlanVersion 1 | Out-Null
    $r = Invoke-Decide $id
    Assert-Fails $r "Stale evidence: it is for plan $($v1.Substring(0, 12)), but the current plan is $($v2.Substring(0, 12))"
    Assert-Equal $true $r.Json.consumed
    # The hash alone binds the decision: the current version number with another plan's hash
    # is still refused.
    Add-TestOnlyLedgerEntry $id 'approve' -PlanSha $v1 -PlanVersion 2 | Out-Null
    $r = Invoke-Decide $id
    Assert-Fails $r "Stale evidence: it is for plan $($v1.Substring(0, 12)), but the current plan is $($v2.Substring(0, 12))"
    Assert-True ($r.Stdout -notmatch 'plan version') 'refused by the hash, not by the version'
    Add-TestOnlyLedgerEntry $id 'approve' -PlanSha $v2 -PlanVersion 1 | Out-Null
    Assert-Fails (Invoke-Decide $id) 'Stale evidence: it is for plan version 1, but the current version is 2'

    # Evidence recorded while the plan is being revised cannot be held back and applied later.
    Assert-Ok (Invoke-Revise $id) | Out-Null
    Add-TestOnlyLedgerEntry $id 'approve' -PlanSha $v2 -PlanVersion 2 | Out-Null
    Assert-Fails (Invoke-Decide $id) "cannot be decided on now: step 'plan' is pending"
    Complete-RevisionCycle $id 'v3' | Out-Null
    Assert-Fails (Invoke-Decide $id) 'No unconsumed decision evidence'

    $s = Read-RunState $id
    Assert-Equal 4 $s.steps.approval.consumed_through
    Assert-Equal 'refused,refused,refused,refused' ((@($s.steps.approval.decisions) | ForEach-Object { $_.outcome }) -join ',')
    Assert-Equal 'awaiting_decision' $s.steps.approval.status
}

Test-Case 'replayed evidence is refused: a copied line breaks the chain, and a re-chained copy reuses its prompt' {
    $id = New-ApprovedRun
    $first = @(Get-LedgerLines $id)[0]
    Add-LedgerLine $id $first
    $r = Invoke-Decide $id
    Assert-Fails $r "line 2: 'seq' must be 2"
    Assert-Equal $false $r.Json.consumed

    $lines = @(Get-LedgerLines $id)
    [System.IO.File]::WriteAllText((Get-LedgerFile $id), "$($lines[0])`n", [System.Text.UTF8Encoding]::new($false))
    $orig = $first | ConvertFrom-Json -AsHashtable
    Add-TestOnlyLedgerEntry $id 'approve' -PromptId $orig.prompt_id | Out-Null
    $r = Invoke-Decide $id
    Assert-Fails $r 'Replayed evidence'
    Assert-Equal $true $r.Json.consumed
    $s = Read-RunState $id
    Assert-Equal 'approved' $s.steps.approval.status
    Assert-Equal 'dec-001' $s.steps.approval.decision_id 'the original approval is unchanged'
}

Test-Case 'reject is final: no later approval, revision, or render' {
    $id = New-ValidatedRun
    Add-TestOnlyLedgerEntry $id 'reject' | Out-Null
    $r = Assert-Ok (Invoke-Decide $id)
    Assert-Equal 'rejected' $r.result
    Assert-Equal 'rejected' $r.workflow_status
    $doc = Get-Content -LiteralPath (Join-Path (Get-RunDir $id) 'approval.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-Equal 'rejected' $doc.decision

    Add-TestOnlyLedgerEntry $id 'approve' | Out-Null
    Assert-Fails (Invoke-Decide $id) 'rejection is final'
    Assert-Fails (Invoke-Revise $id) 'rejection is final'
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) "Approval is 'rejected'"
    $s = Read-RunState $id
    Assert-Equal 'rejected' $s.steps.approval.status
    Assert-Equal 'rejected' $s.workflow_status
    Assert-Equal 0 @($s['revisions'] | Where-Object { $_ }).Count
}

Test-Case 'request changes opens a plan revision with the user''s feedback, voids the approval, and needs a new one' {
    $id = New-ApprovedRun
    $v1 = Get-FileSha $id 'plan.md'
    Add-TestOnlyLedgerEntry $id 'request_changes' -Feedback 'Move the mock interview to day 4.' | Out-Null
    $r = Assert-Ok (Invoke-Decide $id)
    Assert-Equal 'changes_requested' $r.result
    Assert-Equal 'rev-001' $r.revision
    Assert-Equal 'Move the mock interview to day 4.' $r.feedback
    Assert-Equal 2 $r.revisions_left

    $s = Read-RunState $id
    $rev = $s.revisions[0]
    Assert-Equal 'open' $rev.status
    Assert-Equal 'user' $rev.requested_by
    Assert-Equal 'dec-002' $rev.evidence.decision_id
    Assert-Match 'ledger entry dec-002' $rev.user_confirmation
    Assert-Equal 'pending' $s.steps.plan.status
    Assert-Equal 'pending' $s.steps.approval.status
    Assert-Equal 'invalidated' (@($s.steps.approval.history)[-1].result)
    Assert-True (-not (Test-Path (Join-Path (Get-RunDir $id) 'approval.json'))) 'the void approval.json is moved out'
    Assert-Equal 1 @(Get-ChildItem (Join-Path (Get-RunDir $id) 'approval/history') -Filter 'dec-001-invalidated-*.json').Count
    Assert-Equal $v1 (Get-FileSha $id 'versions/plan-v1.md') 'the approved version is kept'

    Complete-RevisionCycle $id 'after-changes' | Out-Null
    Assert-Equal 'awaiting_approval' (Read-RunState $id).workflow_status
    Add-TestOnlyLedgerEntry $id 'approve' | Out-Null
    $r = Assert-Ok (Invoke-Decide $id)
    Assert-Equal 'approved' $r.result
    Assert-True ($r.plan_sha256 -ne $v1) 'the new approval is bound to the revised plan'
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) | Out-Null
}

Test-Case 'a workflow revision voids the approval and the render; a manual plan edit blocks instead, and restore brings the approval back' {
    $id = New-ApprovedRun
    $planSha = Get-FileSha $id 'plan.md'
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) | Out-Null
    Write-Guide $id $planSha
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'render')) | Out-Null

    # Manual edit: an integrity violation. The approval is not invalidated by it.
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id) 'plan.md') -Value "`nEdited by hand." -Encoding utf8NoBOM
    Assert-Fails (Invoke-State @('verify', '-RunId', $id)) 'plan.md changed after it passed'
    $s = Read-RunState $id
    Assert-Equal 'blocked' $s.workflow_status
    Assert-Equal 'approved' $s.steps.approval.status
    Assert-Equal 'passed' $s.steps.render.status
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) 'Integrity violation'
    Assert-Fails (Invoke-Decide $id) 'Integrity violation'
    Assert-Ok (Invoke-State @('resolve', '-RunId', $id, '-Step', 'plan', '-Resolution', 'restore')) | Out-Null
    $s = Read-RunState $id
    Assert-Equal 'completed' $s.workflow_status 'the restored bytes are the approved plan again'
    Assert-Equal 'approved' $s.steps.approval.status

    # A revision through the workflow voids both the approval and the rendered guide.
    Assert-Ok (Invoke-Revise $id) | Out-Null
    $s = Read-RunState $id
    Assert-Equal 'pending' $s.steps.approval.status
    Assert-Equal 'invalidated' (@($s.steps.approval.history)[-1].result)
    Assert-Equal 'pending' $s.steps.render.status
    Assert-Equal 'passed,invalidated' (Get-Results $s.steps.render)
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) 'Render refused'

    # Discarding a manually modified plan also voids the approval.
    $id2 = New-ApprovedRun
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id2) 'plan.md') -Value "`nEdited by hand." -Encoding utf8NoBOM
    Assert-Ok (Invoke-State @('resolve', '-RunId', $id2, '-Step', 'plan', '-Resolution', 'discard')) | Out-Null
    $s = Read-RunState $id2
    Assert-Equal 'pending' $s.steps.approval.status
    Assert-Match 'step .plan. is pending' ((@($s.steps.approval.history)[-1].reasons) -join ' ')
}

Test-Case 'tampering with approval.json or consumed ledger entries blocks the run; new unconsumed entries do not' {
    $id = New-ApprovedRun
    $path = Join-Path (Get-RunDir $id) 'approval.json'
    (Get-Content -LiteralPath $path -Raw).Replace('"approved"', '"approved" ') | Set-Content -LiteralPath $path -Encoding utf8NoBOM -NoNewline
    Assert-Fails (Invoke-State @('verify', '-RunId', $id)) 'approval.json changed after it passed'
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) 'Integrity violation'
    Assert-Ok (Invoke-State @('resolve', '-RunId', $id, '-Step', 'approval', '-Resolution', 'restore')) | Out-Null
    Assert-Ok (Invoke-State @('verify', '-RunId', $id)) | Out-Null

    $ledgerPath = Get-LedgerFile $id
    $original = [System.IO.File]::ReadAllText($ledgerPath)
    [System.IO.File]::WriteAllText($ledgerPath, $original.Replace('"plan_version":1', '"plan_version":9'), [System.Text.UTF8Encoding]::new($false))
    Assert-Fails (Invoke-State @('verify', '-RunId', $id)) 'decisions.jsonl changed after decisions in it were consumed'
    Assert-Fails (Invoke-Decide $id) 'Integrity violation'
    Assert-Fails (Invoke-State @('start', '-RunId', $id, '-Step', 'render')) 'Integrity violation'
    Assert-Fails (Invoke-State @('resolve', '-RunId', $id, '-Step', 'approval-ledger', '-Resolution', 'restore')) 'by hand'
    [System.IO.File]::WriteAllText($ledgerPath, '', [System.Text.UTF8Encoding]::new($false))
    Assert-Fails (Invoke-State @('verify', '-RunId', $id)) 'found missing' 'deleted consumed entries are detected too'
    [System.IO.File]::WriteAllText($ledgerPath, $original, [System.Text.UTF8Encoding]::new($false))
    Assert-Ok (Invoke-State @('verify', '-RunId', $id)) | Out-Null

    Add-TestOnlyLedgerEntry $id 'reject' | Out-Null
    Assert-Ok (Invoke-State @('verify', '-RunId', $id)) 'appending is how evidence arrives; it is not tampering' | Out-Null
}

Test-Case 'runs created before approval existed get the approval and render steps, and nothing else changes' {
    # A run with history: a revision (two plan versions, archived request) and a plan-validation
    # report history, so every kind of recorded state is exercised by the upgrade.
    $id = New-ValidatedRun
    Assert-Ok (Invoke-Revise $id) | Out-Null
    Complete-RevisionCycle $id 'before-upgrade' | Out-Null
    $dir = Get-RunDir $id
    $statePath = Join-Path $dir 'state.json'
    $raw = Read-RunState $id
    $raw.steps.Remove('approval'); $raw.steps.Remove('render')
    $raw.workflow_status = 'paused'; $raw.current_step = $null; $raw.next_step = 'approval (not implemented yet)'
    $raw | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
    $before = Read-RunState $id
    $files = [ordered]@{}
    Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Name -ne 'state.json' } | Sort-Object FullName |
        ForEach-Object { $files[$_.FullName.Substring($dir.Length + 1)] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    Assert-True ($files.Keys -contains 'versions\plan-v2.md' -or $files.Keys -contains 'versions/plan-v2.md') 'the fixture has version snapshots'

    Assert-Ok (Invoke-State @('verify', '-RunId', $id)) | Out-Null
    $s = Read-RunState $id
    Assert-Equal 'awaiting_decision' $s.steps.approval.status
    Assert-Equal 'pending' $s.steps.render.status
    Assert-Equal 'awaiting_approval' $s.workflow_status

    # Every existing step is unchanged field for field: status, artifact and input hashes,
    # attempts, accepted versions, revisions, and history.
    Assert-Equal ((@($before.steps.Keys) + @('approval', 'render')) -join ',') (@($s.steps.Keys) -join ',')
    foreach ($name in $before.steps.Keys) {
        Assert-Equal (ConvertTo-Snapshot $before.steps[$name]) (ConvertTo-Snapshot $s.steps[$name]) "step $name changed"
    }
    foreach ($k in $before.Keys) {
        if ($k -in 'steps', 'workflow_status', 'current_step', 'next_step', 'updated_at') { continue }
        Assert-Equal (ConvertTo-Snapshot $before[$k]) (ConvertTo-Snapshot $s[$k]) "top-level '$k' changed"
    }
    # No file other than state.json was touched or added.
    $after = [ordered]@{}
    Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Name -ne 'state.json' } | Sort-Object FullName |
        ForEach-Object { $after[$_.FullName.Substring($dir.Length + 1)] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    Assert-Equal (ConvertTo-Snapshot $files) (ConvertTo-Snapshot $after) 'run files changed'
}

Write-Section 'decision ledger quarantine (Phase 4A)'

function Invoke-Quarantine([string]$RunId) { Invoke-State @('quarantine-ledger', '-RunId', $RunId, '-Reason', 'test: malformed evidence') }

Test-Case 'quarantine moves the malformed suffix only; consumed and earlier valid entries stay and stay usable' {
    $id = New-ApprovedRun
    $a0 = (Read-RunState $id).steps.approval
    Add-TestOnlyLedgerEntry $id 'request_changes' -Feedback 'Shorter day 1.' | Out-Null
    Add-LedgerLine $id '{"not":"an entry"'
    Add-LedgerLine $id ('{"seq":4,"decision":"approve","source":"user-prompt-submit"}')
    $lines = @(Get-LedgerLines $id)
    Assert-Fails (Invoke-Decide $id) 'line 3 is not a JSON object'

    $r = Assert-Ok (Invoke-Quarantine $id)
    Assert-Equal 'quarantined' $r.result
    Assert-Equal 'q-001' $r.quarantine
    Assert-Equal 3 $r.first_line
    Assert-Equal 2 $r.line_count
    Assert-Equal 2 $r.kept_lines
    Assert-Equal 'approved' $r.approval_status 'quarantine never changes the decision'

    $q = Join-Path (Get-RunDir $id) 'approval/quarantine/q-001.jsonl'
    Assert-Equal (($lines[2], $lines[3]) -join "`n") ((Get-Content -LiteralPath $q -Raw).TrimEnd("`n")) 'the quarantined lines are kept verbatim'
    Assert-Equal (($lines[0], $lines[1]) -join ',') ((@(Get-LedgerLines $id)) -join ',') 'consumed and earlier valid entries stay'
    $s = Read-RunState $id
    $a = $s.steps.approval
    Assert-Equal $a0.consumed_through $a.consumed_through
    Assert-Equal $a0.consumed_sha256 $a.consumed_sha256
    Assert-Equal $a0.artifact_sha256 $a.artifact_sha256
    $rec = $a.ledger_quarantines[0]
    Assert-Equal 'completed' $rec.status
    Assert-Equal 'test: malformed evidence' $rec.reason
    Assert-Equal $rec.quarantined_sha256 (Get-FileSha $id 'approval/quarantine/q-001.jsonl')
    Assert-Equal $rec.kept_sha256 (Get-FileSha $id 'approval/decisions.jsonl')
    Assert-True ($rec.original_sha256 -ne $rec.kept_sha256) 'original hash recorded'
    Assert-Equal 'ledger_quarantined' (@($a.history)[-1].result)
    Assert-Ok (Invoke-State @('verify', '-RunId', $id)) | Out-Null

    # The kept valid entry (dec-002) is still applied normally afterwards.
    $d = Assert-Ok (Invoke-Decide $id)
    Assert-Equal 'changes_requested' $d.result
    Assert-Equal 'dec-002' $d.decision_id
    Assert-NoLeftovers $id
}

Test-Case 'quarantine refuses a valid or missing ledger, is idempotent, and never creates or applies a decision' {
    $id = New-ValidatedRun
    Assert-Fails (Invoke-Quarantine $id) 'There is no decision ledger'
    Add-TestOnlyLedgerEntry $id 'approve' | Out-Null
    $ledgerSha = Get-FileSha $id 'approval/decisions.jsonl'
    $before = ConvertTo-Snapshot (Read-RunState $id).steps
    Assert-Fails (Invoke-Quarantine $id) 'structurally valid; there is nothing to quarantine'
    Assert-Equal $ledgerSha (Get-FileSha $id 'approval/decisions.jsonl')
    Assert-Equal $before (ConvertTo-Snapshot (Read-RunState $id).steps) 'a refused quarantine changes nothing'

    # Only malformed line(s): the whole unconsumed ledger moves; the run still awaits the user.
    Remove-Item -LiteralPath (Get-LedgerFile $id) -Force
    Add-TestOnlyLedgerEntry $id 'approve' -Override @{ source = 'coordinator' } | Out-Null
    $r = Assert-Ok (Invoke-Quarantine $id)
    Assert-Equal 0 $r.kept_lines
    Assert-Equal 'awaiting_decision' $r.approval_status
    Assert-Equal 0 @(Get-LedgerLines $id).Count
    Assert-True (-not (Test-Path (Join-Path (Get-RunDir $id) 'approval.json'))) 'no approval.json'
    $snap = ConvertTo-Snapshot (Read-RunState $id)
    Assert-Fails (Invoke-Quarantine $id) 'nothing to quarantine' 'repeating it is refused'
    Assert-Equal $snap (ConvertTo-Snapshot (Read-RunState $id)) 'and changes nothing'
    Assert-Fails (Invoke-Decide $id) 'No unconsumed decision evidence' 'nothing was turned into a decision'

    # A later malformed line gets its own quarantine record.
    Add-LedgerLine $id 'garbage'
    Assert-Equal 'q-002' (Assert-Ok (Invoke-Quarantine $id)).quarantine
    $s = Read-RunState $id
    Assert-Equal 'awaiting_decision' $s.steps.approval.status
    Assert-Equal 0 $s.steps.approval.consumed_through
    Assert-Equal 'completed,completed' ((@($s.steps.approval.ledger_quarantines) | ForEach-Object { $_.status }) -join ',')
    Assert-NoLeftovers $id
}

Test-Case 'quarantine interrupted before or after rewriting the ledger is resumed by running it again' {
    $id = New-ValidatedRun
    Add-TestOnlyLedgerEntry $id 'approve' | Out-Null
    Add-LedgerLine $id 'garbage'
    $original = Get-FileSha $id 'approval/decisions.jsonl'

    # Failure before the ledger changes: the quarantine file cannot be written.
    $obstacle = Join-Path (Get-RunDir $id) 'approval/quarantine/q-001.jsonl'
    New-Item -ItemType Directory -Path $obstacle -Force | Out-Null
    Assert-Fails (Invoke-Quarantine $id)
    Assert-Equal $original (Get-FileSha $id 'approval/decisions.jsonl') 'the ledger is untouched'
    $s = Read-RunState $id
    Assert-Equal 'started' $s.steps.approval.ledger_quarantines[0].status 'the intent was recorded first'
    Assert-Fails (Invoke-Decide $id) 'q-001 was interrupted'
    Remove-Item -LiteralPath $obstacle -Force
    $r = Assert-Ok (Invoke-Quarantine $id)
    Assert-Equal 'q-001' $r.quarantine 'the same quarantine is resumed, not a new one'
    $s = Read-RunState $id
    Assert-Equal 1 @($s.steps.approval.ledger_quarantines).Count
    Assert-Equal 'completed' $s.steps.approval.ledger_quarantines[0].status
    $kept = Get-FileSha $id 'approval/decisions.jsonl'
    $qSha = Get-FileSha $id 'approval/quarantine/q-001.jsonl'

    # Interrupted after the ledger was rewritten, before the final save.
    $raw = Read-RunState $id
    $raw.steps.approval.ledger_quarantines[0].status = 'started'
    $raw.steps.approval.ledger_quarantines[0].completed_at = $null
    $raw.steps.approval.history = @(@($raw.steps.approval.history) | Where-Object { $_.result -ne 'ledger_quarantined' })
    $raw | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path (Get-RunDir $id) 'state.json') -Encoding utf8NoBOM
    Assert-Equal 'q-001' (Assert-Ok (Invoke-Quarantine $id)).quarantine
    Assert-Equal $kept (Get-FileSha $id 'approval/decisions.jsonl') 'the ledger is not rewritten twice'
    Assert-Equal $qSha (Get-FileSha $id 'approval/quarantine/q-001.jsonl')
    $s = Read-RunState $id
    Assert-Equal 'completed' $s.steps.approval.ledger_quarantines[0].status
    Assert-Equal 1 @(@($s.steps.approval.history) | Where-Object { $_.result -eq 'ledger_quarantined' }).Count

    # The kept entry is still valid evidence.
    Assert-Equal 'approved' (Assert-Ok (Invoke-Decide $id)).result

    # A resume is refused if the files no longer match the recorded hashes.
    $id2 = New-ValidatedRun
    Add-LedgerLine $id2 'garbage'
    New-Item -ItemType Directory -Path (Join-Path (Get-RunDir $id2) 'approval/quarantine/q-001.jsonl') -Force | Out-Null
    Assert-Fails (Invoke-Quarantine $id2)
    Add-LedgerLine $id2 'more garbage'
    Remove-Item -LiteralPath (Join-Path (Get-RunDir $id2) 'approval/quarantine/q-001.jsonl') -Force
    Assert-Fails (Invoke-Quarantine $id2) 'cannot be resumed: the ledger is neither the original'
    Assert-Equal 'started' (Read-RunState $id2).steps.approval.ledger_quarantines[0].status
}

Test-Case 'quarantine refuses to touch a ledger whose consumed entries were changed' {
    $id = New-ApprovedRun
    $path = Get-LedgerFile $id
    $original = [System.IO.File]::ReadAllText($path)
    [System.IO.File]::WriteAllText($path, $original.Replace('"plan_version":1', '"plan_version":7') + "garbage`n", [System.Text.UTF8Encoding]::new($false))
    $tampered = Get-FileSha $id 'approval/decisions.jsonl'
    Assert-Fails (Invoke-Quarantine $id) 'Integrity violation: .*decisions.jsonl changed after decisions in it were consumed'
    Assert-Equal $tampered (Get-FileSha $id 'approval/decisions.jsonl') 'nothing is rewritten'
    Assert-True (-not (Test-Path (Join-Path (Get-RunDir $id) 'approval/quarantine'))) 'nothing is quarantined'
    Assert-Equal 'blocked' (Read-RunState $id).workflow_status
}
