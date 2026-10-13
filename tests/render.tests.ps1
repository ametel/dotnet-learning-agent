#Requires -Version 7.0
# Phase 5 tests: the HTML renderer (scripts/render-guide.ps1). Rendering is allowed only for
# a valid approval of exactly the current plan; the output is escaped, self-contained, and
# recorded with its hash. Dot-sourced by tests/run-tests.ps1 after hooks.tests.ps1
# (New-ApprovedRun, New-ValidatedRun, Invoke-Revise, Invoke-ToolHook, ...).

$script:Renderer = (Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'render-guide.ps1')).Path

function Invoke-Render([string]$RunId) {
    $output = & pwsh -NoProfile -NonInteractive -File $script:Renderer -RunId $RunId -RunsRoot $script:RunsRoot -StateScript $script:StateScript 2>&1
    $code = $LASTEXITCODE
    $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $json = $null
    if ($stdout.Trim()) { try { $json = $stdout | ConvertFrom-Json -AsHashtable } catch { } }
    [pscustomobject]@{ ExitCode = $code; Stdout = $stdout; Json = $json }
}

function Get-Guide([string]$RunId) { Get-Content -LiteralPath (Join-Path (Get-RunDir $RunId) 'guide.html') -Raw }

Write-Section 'HTML guide rendering (Phase 5)'

Test-Case 'an approved plan renders to guide.html with schedule, exercises, interview questions, and sources; the run completes' {
    $id = New-ApprovedRun
    $planSha = Get-FileSha $id 'plan.md'
    $before = @{}
    foreach ($rel in 'plan.md', 'approval.json', 'research/data.md', 'validation/plan.json') { $before[$rel] = Get-FileSha $id $rel }

    $r = Invoke-Render $id
    Assert-Equal 0 $r.ExitCode $r.Stdout
    Assert-Equal 'passed' $r.Json.result
    Assert-Equal 'completed' $r.Json.workflow_status
    Assert-Equal $planSha $r.Json.plan_sha256

    $html = Get-Guide $id
    Assert-Match "<meta name=`"plan-sha256`" content=`"$planSha`">" $html 'the guide is bound to the approved plan hash'
    Assert-Match '<title>Study Plan: Senior \.NET backend</title>' $html
    Assert-Match '<table>' $html 'the schedule table is rendered'
    Assert-Match '<th>Minutes</th>' $html
    Assert-Match '<h2 id="topic-plans">Topic Plans</h2>' $html
    Assert-Match '<h3 id="ef-core-performance">EF Core performance</h3>' $html
    Assert-Match '<li>Practice: exercise\.</li>' $html 'exercises are rendered'
    Assert-Match '<li>Interview: questions\.</li>' $html 'interview questions are rendered'
    Assert-Match '<a href="https://learn\.microsoft\.com/dotnet/a">docs</a>' $html 'sources are links'
    Assert-Match 'href="#schedule"' $html 'section navigation'
    Assert-True ($html -notmatch '<script') 'no scripts'
    Assert-True ($html -notmatch '(src|href)="(?!https?://|#)') 'no non-http links or embedded resources'
    Assert-Match "Content-Security-Policy`" content=`"default-src 'none'" $html

    $s = Read-RunState $id
    Assert-Equal 'passed' $s.steps.render.status
    Assert-Equal (Get-FileSha $id 'guide.html') $s.steps.render.artifact_sha256 'the output hash is recorded'
    Assert-Equal $s.steps.render.artifact_sha256 (Get-FileSha $id 'versions/render-v1.html') 'and snapshotted'
    foreach ($rel in $before.Keys) { Assert-Equal $before[$rel] (Get-FileSha $id $rel) "$rel is not changed by rendering" }
    Assert-NoLeftovers $id
}

Test-Case 'rendering is refused without an approval, and writes nothing' {
    $id = New-ValidatedRun
    $r = Invoke-Render $id
    Assert-Equal 1 $r.ExitCode
    Assert-Equal 'refused' $r.Json.result
    Assert-Match "Render refused: there is no valid approval of the current plan\. Approval is 'awaiting_decision'" $r.Json.reason
    Assert-True (-not (Test-Path (Join-Path (Get-RunDir $id) 'guide.html'))) 'no guide.html'
    $s = Read-RunState $id
    Assert-Equal 'pending' $s.steps.render.status
    Assert-Equal 0 $s.steps.render.attempts 'a refusal is not an attempt'

    # A model-written approval.json is not an approval either.
    '{"decision":"approved"}' | Set-Content -LiteralPath (Join-Path (Get-RunDir $id) 'approval.json') -Encoding utf8NoBOM
    Assert-Equal 'refused' (Invoke-Render $id).Json.result
    Assert-True (-not (Test-Path (Join-Path (Get-RunDir $id) 'guide.html'))) 'still no guide.html'
}

Test-Case 'a plan changed after approval cannot be rendered: a revision voids the approval, a manual edit blocks the run' {
    # Revised and validated again, but not approved again: the old approval is void.
    $id = New-ApprovedRun
    Assert-Ok (Invoke-Revise $id) | Out-Null
    Complete-RevisionCycle $id 'after-approval' | Out-Null
    $r = Invoke-Render $id
    Assert-Equal 'refused' $r.Json.result
    Assert-Match "Approval is 'awaiting_decision'" $r.Json.reason
    Assert-True (-not (Test-Path (Join-Path (Get-RunDir $id) 'guide.html'))) 'no guide for an unapproved plan version'

    # Edited by hand after approval: an integrity violation; nothing is rendered.
    $id2 = New-ApprovedRun
    Add-Content -LiteralPath (Join-Path (Get-RunDir $id2) 'plan.md') -Value "`nEdited after approval." -Encoding utf8NoBOM
    $r = Invoke-Render $id2
    Assert-Equal 'refused' $r.Json.result
    Assert-Match 'Integrity violation' $r.Json.reason
    Assert-True (-not (Test-Path (Join-Path (Get-RunDir $id2) 'guide.html'))) 'no guide for a modified plan'
    Assert-Equal 'blocked' (Read-RunState $id2).workflow_status
}

Test-Case 'plan text is HTML-escaped: no markup, script, event handler, or non-http link reaches the guide' {
    $id = New-ResearchedRun
    Complete-Coverage $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    $hostile = @(
        ''
        '## Notes'
        'A <script>alert("x")</script> tag, an <img src=x onerror=alert(1)> image, and & < > " '' characters.'
        '- [click](javascript:alert(1)) and [data](data:text/html,<b>x</b>)'
        '- https://learn.microsoft.com/dotnet/a"onmouseover="alert(1)'
        '| Col <b>1</b> | `<code>` |'
        '|---|---|'
        '| <i>cell</i> | **bold <u>u</u>** |'
    ) -join "`n"
    Write-Plan $id ((Get-PlanText) + "`n" + $hostile)
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan', '-AgentId', 'planner-x')) | Out-Null
    Complete-PlanValidation $id | Out-Null
    Add-TestOnlyLedgerEntry $id 'approve' | Out-Null
    Assert-Equal 'approved' (Assert-Ok (Invoke-Decide $id)).result

    $r = Invoke-Render $id
    Assert-Equal 'passed' $r.Json.result $r.Stdout
    $html = Get-Guide $id
    Assert-True ($html -notmatch '<script') 'no script element'
    Assert-True ($html -notmatch '<img|<b>|<i>|<u>') 'no markup from the plan'
    Assert-True ($html -notmatch '(?i)<[^>]*\son[a-z]+=') 'no event-handler attribute in any tag'
    Assert-True ($html -notmatch '(?i)href="(javascript|data):') 'no javascript: or data: link'
    Assert-Match '&lt;script&gt;alert\(&quot;x&quot;\)&lt;/script&gt;' $html 'the text is shown, escaped'
    Assert-Match '&amp; &lt; &gt; &quot; &#39; characters' $html
    Assert-Match '<a href="https://learn\.microsoft\.com/dotnet/a">https://learn\.microsoft\.com/dotnet/a</a>&quot;onmouseover=&quot;alert\(1\)' $html 'a quote ends the URL; the rest is text'
    Assert-Match '<th>Col &lt;b&gt;1&lt;/b&gt;</th>' $html
    Assert-Match '<code>&lt;code&gt;</code>' $html
    Assert-Match '<strong>bold &lt;u&gt;u&lt;/u&gt;</strong>' $html
}

Test-Case 'numbered lists keep their text: interview questions are rendered, nested and top-level' {
    # Regression: the first real render (2026-10-13) emitted every numbered item as an empty
    # <li></li>, because a -match inside the list branch overwrote $Matches.
    $id = New-ResearchedRun
    Complete-Coverage $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'plan')) | Out-Null
    $drill = @(
        ''
        '## Interview Drill'
        '- **Interview questions (5 min, Day 1):**'
        '  1. *When would you use AsNoTracking?* Strong answer covers: read-only paths.'
        '  2. *What is N+1?* Strong answer covers: one query per parent, `Include` fixes it.'
        '- **Mock interview:**'
        '1. Top-level numbered question.'
        '2. Second top-level question.'
    ) -join "`n"
    Write-Plan $id ((Get-PlanText) + "`n" + $drill)
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'plan', '-AgentId', 'planner-n')) | Out-Null
    Complete-PlanValidation $id | Out-Null
    Add-TestOnlyLedgerEntry $id 'approve' | Out-Null
    Assert-Equal 'approved' (Assert-Ok (Invoke-Decide $id)).result

    Assert-Equal 'passed' (Invoke-Render $id).Json.result
    $html = Get-Guide $id
    Assert-True ($html -notmatch '<li>\s*</li>') 'no empty list items'
    Assert-Match '<ol>\s*<li>\*When would you use AsNoTracking\?\* Strong answer covers: read-only paths\.</li>\s*<li>\*What is N\+1\?\* Strong answer covers: one query per parent, <code>Include</code> fixes it\.</li></ol>' $html 'nested numbered questions keep their text'
    Assert-Match '<ol>\s*<li>Top-level numbered question\.</li>\s*<li>Second top-level question\.</li></ol>' $html 'top-level numbered items keep their text'
}

Test-Case 'the rendered guide is integrity-protected: tampering is detected, a second render is refused, direct writes are denied' {
    $id = New-ApprovedRun
    Assert-Equal 'passed' (Invoke-Render $id).Json.result
    $guide = Join-Path (Get-RunDir $id) 'guide.html'

    $r = Invoke-Render $id
    Assert-Equal 'refused' $r.Json.result
    Assert-Match "Step 'render' already passed" $r.Json.reason
    $r = Invoke-ToolHook 'PreToolUse' 'Write' @{ file_path = $guide; content = '<p>forged</p>' } ''
    Assert-Equal 'deny' $r.Json.hookSpecificOutput.permissionDecision
    $r = Invoke-ToolHook 'PreToolUse' 'Bash' @{ command = "pwsh -NoProfile -File scripts/render-guide.ps1 -RunId $id" } ''
    Assert-True (-not $r.Json) 'the renderer command is allowed by the shell policy'
    $r = Invoke-ToolHook 'PreToolUse' 'Bash' @{ command = "pwsh -NoProfile -File scripts/render-guide.ps1 -RunId $id; rm x" } ''
    Assert-Equal 'deny' $r.Json.hookSpecificOutput.permissionDecision 'but not with shell operators'

    Add-Content -LiteralPath $guide -Value '<p>tampered</p>' -Encoding utf8NoBOM
    Assert-Fails (Invoke-State @('verify', '-RunId', $id)) 'guide\.html changed after it passed'
    Assert-Equal 'blocked' (Read-RunState $id).workflow_status
    Assert-Ok (Invoke-State @('resolve', '-RunId', $id, '-Step', 'render', '-Resolution', 'restore')) | Out-Null
    Assert-Equal (Read-RunState $id).steps.render.artifact_sha256 (Get-FileSha $id 'guide.html') 'restored from the snapshot'
    Assert-Equal 'completed' (Read-RunState $id).workflow_status
}
