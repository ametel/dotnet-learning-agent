#Requires -Version 7.0
# Dependency-free test kit for scripts/state.ps1. Dot-sourced by tests/run-tests.ps1.
# Every test run gets its own directory under the system temp folder; nothing is written
# to the repository's runs/ directory.

$ErrorActionPreference = 'Stop'
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:Notes = [System.Collections.Generic.List[string]]::new()

function Initialize-TestKit([string]$StateScript) {
    $script:StateScript = $StateScript
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dla-state-tests-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $script:RunsRoot = Join-Path $script:TestRoot 'runs'
    New-Item -ItemType Directory -Path $script:RunsRoot -Force | Out-Null
}

# ---------------------------------------------------------------- test runner and asserts

function Test-Case([string]$Name, [scriptblock]$Body) {
    # run-tests.ps1 -Filter <regex> runs only the matching tests.
    if ($script:CaseFilter -and $Name -notmatch $script:CaseFilter) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
        $script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null; Seconds = $sw.Elapsed.TotalSeconds })
        Write-Host ("  PASS  {0} ({1:N1}s)" -f $Name, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    }
    catch {
        $where = $_.InvocationInfo.ScriptLineNumber
        $script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = "$($_.Exception.Message) (line $where)"; Seconds = $sw.Elapsed.TotalSeconds })
        Write-Host ("  FAIL  {0}: {1} (line {2})" -f $Name, $_.Exception.Message, $where) -ForegroundColor Red
    }
}

function Write-Section([string]$Title) { Write-Host "`n$Title" -ForegroundColor Cyan }

function Add-Note([string]$Text) { $script:Notes.Add($Text); Write-Host "        $Text" -ForegroundColor DarkGray }

function Assert-True($Condition, [string]$Message = 'Expected condition to be true') {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal($Expected, $Actual, [string]$Message = '') {
    if ("$Expected" -ne "$Actual") { throw "Assertion failed: expected '$Expected' but got '$Actual'. $Message" }
}

function Assert-Match([string]$Pattern, $Actual, [string]$Message = '') {
    if ("$Actual" -notmatch $Pattern) { throw "Assertion failed: '$Actual' does not match /$Pattern/. $Message" }
}

# Asserts that a state.ps1 invocation succeeded (exit 0) and returns its parsed JSON output.
function Assert-Ok($Result, [string]$Message = '') {
    if ($Result.ExitCode -ne 0) { throw "Expected success but exit code was $($Result.ExitCode). stdout: $($Result.Stdout) stderr: $($Result.Stderr) $Message" }
    return $Result.Json
}

function Assert-Fails($Result, [string]$Pattern = '.', [string]$Message = '') {
    if ($Result.ExitCode -eq 0) { throw "Expected failure but the call succeeded. stdout: $($Result.Stdout) $Message" }
    Assert-Match $Pattern "$($Result.Stdout) $($Result.Stderr)" $Message
}

function Write-TestSummary {
    $failed = @($script:Results | Where-Object { -not $_.Passed })
    $total = $script:Results.Count
    Write-Host ''
    Write-Host ("{0} tests, {1} passed, {2} failed ({3:N1}s)" -f $total, ($total - $failed.Count), $failed.Count, (($script:Results | Measure-Object Seconds -Sum).Sum)) -ForegroundColor ($failed.Count ? 'Red' : 'Green')
    foreach ($f in $failed) { Write-Host "  FAILED: $($f.Name): $($f.Error)" -ForegroundColor Red }
    return $failed.Count
}

# ---------------------------------------------------------------- invoking state.ps1

# Runs state.ps1 in a separate pwsh process, exactly as the coordinator does.
function Invoke-State([string[]]$Arguments) {
    $output = & pwsh -NoProfile -NonInteractive -File $script:StateScript @Arguments -RunsRoot $script:RunsRoot 2>&1
    $code = $LASTEXITCODE
    $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
    $json = $null
    if ($stdout.Trim()) { try { $json = $stdout | ConvertFrom-Json -AsHashtable } catch { $json = $null } }
    [pscustomobject]@{ ExitCode = $code; Stdout = $stdout; Stderr = $stderr; Json = $json }
}

# ---------------------------------------------------------------- fixtures

function Get-RunDir([string]$RunId) { Join-Path $script:RunsRoot $RunId }

function Read-RunState([string]$RunId) {
    Get-Content -LiteralPath (Join-Path (Get-RunDir $RunId) 'state.json') -Raw | ConvertFrom-Json -AsHashtable
}

function New-Run([string]$Label = 'test') {
    (Assert-Ok (Invoke-State @('init', '-Label', $Label))).run_id
}

function Write-ConfirmedInput([string]$RunId, [string]$Text = "# Confirmed Requirements`n`n## Seniority`nSenior`n`nConfirmed by user: yes") {
    Set-Content -LiteralPath (Join-Path (Get-RunDir $RunId) 'confirmed-input.md') -Value $Text -Encoding utf8NoBOM
}

$script:RequirementsHeadings = @(
    '# Interview Preparation Requirements', '## Summary', '## Target Role and Seniority', '## Topics',
    '## Knowledge Gaps', '## Time Availability', '## Learning Preferences', '## Constraints',
    '## Acceptance Criteria', '## Open Questions and Assumptions'
)

# Mandatory topics (requirements.md front matter) per research area, and the research topic
# each one maps to in research-selection.json.
$script:MandatoryByArea = [ordered]@{
    dotnet       = [ordered]@{ 'async internals' = 'Async internals in .NET'; 'concurrency' = 'Concurrency in .NET' }
    data         = [ordered]@{ 'EF Core performance' = 'EF Core performance' }
    architecture = [ordered]@{ 'system design' = 'System design' }
}

function Get-MandatoryTopics([string[]]$Areas = @('dotnet', 'data', 'architecture')) {
    @(foreach ($a in $script:MandatoryByArea.Keys) { if ($Areas -contains $a) { $script:MandatoryByArea[$a].Keys } })
}

function Get-RequirementsText {
    param(
        [int]$Blocking = 0,
        [string[]]$OmitHeadings = @(),
        [string]$BlockingValue,
        [string[]]$Mandatory = (Get-MandatoryTopics),
        [string]$Budget = '15',
        [string[]]$OptionalTopics = @('ASP.NET Core Web APIs review')
    )
    $value = if ($PSBoundParameters.ContainsKey('BlockingValue')) { $BlockingValue } else { "$Blocking" }
    $lines = @('---', 'artifact: requirements', 'generated_by: requirements-formalizer', "blocking_open_questions: $value")
    if ($Mandatory.Count) { $lines += @('mandatory_topics:') + @($Mandatory | ForEach-Object { "  - $_" }) }
    if ($Budget) { $lines += "time_budget_hours: $Budget" }
    $lines += @('---', '')
    foreach ($h in $script:RequirementsHeadings) {
        if ($OmitHeadings -contains $h) { continue }
        $lines += $h
        switch ($h) {
            '## Knowledge Gaps' { $lines += @($Mandatory | ForEach-Object { "- $_ (stated)" }) }
            '## Topics' { $lines += @($Mandatory | ForEach-Object { "- $_ | High | (stated)" }) + @($OptionalTopics | ForEach-Object { "- $_ | Low | (derived)" }) }
            default { $lines += 'Content.' }
        }
        $lines += ''
    }
    $lines -join "`n"
}

function Write-Requirements([string]$RunId, [string]$Text = (Get-RequirementsText)) {
    Set-Content -LiteralPath (Join-Path (Get-RunDir $RunId) 'requirements.md') -Value $Text -Encoding utf8NoBOM -NoNewline
}

# A run whose requirements step has passed. Mandatory topics default to those of $Areas.
function New-PassedRun([int]$Blocking = 0, [string[]]$Areas = @('dotnet', 'data', 'architecture'), [string]$Budget = '15') {
    $id = New-Run
    Write-ConfirmedInput $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    Write-Requirements $id (Get-RequirementsText -Blocking $Blocking -Mandatory (Get-MandatoryTopics $Areas) -Budget $Budget)
    Assert-Ok (Invoke-State @('complete', '-RunId', $id, '-Step', 'requirements', '-AgentId', 'req-agent')) | Out-Null
    return $id
}

$script:DefaultTopics = [ordered]@{
    dotnet       = @('Async internals in .NET', 'Concurrency in .NET')
    data         = @('EF Core performance')
    architecture = @('System design')
}
$script:AgentByArea = @{ dotnet = 'dotnet-researcher'; data = 'data-researcher'; architecture = 'architecture-researcher' }

function Write-Selection([string]$RunId, $Selection) {
    $path = Join-Path (Get-RunDir $RunId) 'research-selection.json'
    $Selection | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function Get-DefaultSelection([string[]]$Areas = @('dotnet', 'data', 'architecture')) {
    $selected = @(); $notSelected = @(); $coverage = @()
    foreach ($area in $script:DefaultTopics.Keys) {
        if ($Areas -contains $area) {
            $selected += @{ agent = $script:AgentByArea[$area]; topics = $script:DefaultTopics[$area]; reason = "Gap in $area." }
            foreach ($m in $script:MandatoryByArea[$area].Keys) { $coverage += @{ mandatory_topic = $m; research_topics = @($script:MandatoryByArea[$area][$m]) } }
        }
        else { $notSelected += @{ agent = $script:AgentByArea[$area]; reason = "No $area gap." } }
    }
    @{ selected = $selected; not_selected = $notSelected; coverage = $coverage }
}

# A run with requirements passed and the given research areas selected.
function New-SelectedRun([string[]]$Areas = @('dotnet', 'data', 'architecture'), [string]$Budget = '15') {
    $id = New-PassedRun -Areas $Areas -Budget $Budget
    $path = Write-Selection $id (Get-DefaultSelection $Areas)
    Assert-Ok (Invoke-State @('select', '-RunId', $id, '-SelectionFile', $path)) | Out-Null
    return $id
}

function Get-ResearchText {
    param(
        [string]$Area,
        [string[]]$Topics = $script:DefaultTopics[$Area],
        [string[]]$Sources = @('https://learn.microsoft.com/dotnet/a', 'https://learn.microsoft.com/ef/b', 'https://github.com/dotnet/c'),
        [string]$GeneratedBy = $script:AgentByArea[$Area],
        [string[]]$OmitHeadings = @()
    )
    $lines = @('---', 'artifact: research', "area: $Area", "generated_by: $GeneratedBy", '---', '', "# Research: $Area", '')
    foreach ($h in '## Scope', '## Findings') {
        if ($OmitHeadings -notcontains $h) { $lines += @($h, 'Text with an inline link https://example.com/inline-not-a-source.', '') }
        if ($h -eq '## Findings') { foreach ($t in $Topics) { $lines += @("### $t", "- Finding about $t.", '') } }
    }
    foreach ($h in '## Interview Questions', '## Hands-on Exercises') { if ($OmitHeadings -notcontains $h) { $lines += @($h, '1. Item.', '') } }
    if ($OmitHeadings -notcontains '## Sources') { $lines += @('## Sources') + @($Sources | ForEach-Object { "- Source: $_" }) + @('') }
    if ($OmitHeadings -notcontains '## Gaps and Limitations') { $lines += @('## Gaps and Limitations', 'None.') }
    $lines -join "`n"
}

function Write-Research([string]$RunId, [string]$Area, [string]$Text = (Get-ResearchText -Area $Area)) {
    Set-Content -LiteralPath (Join-Path (Get-RunDir $RunId) "research/$Area.md") -Value $Text -Encoding utf8NoBOM -NoNewline
}

# Runs start → write valid artifact → complete for each research area.
function Complete-Research([string]$RunId, [string[]]$Areas = @('dotnet', 'data', 'architecture')) {
    foreach ($area in $Areas) {
        Assert-Ok (Invoke-State @('start', '-RunId', $RunId, '-Step', "research-$area")) | Out-Null
        Write-Research $RunId $area
        Assert-Ok (Invoke-State @('complete', '-RunId', $RunId, '-Step', "research-$area", '-AgentId', "agent-$area")) | Out-Null
    }
}

# A quality-validator report. $Statuses maps mandatory topic -> covered|partial|missing
# (default: all covered). $Findings are hashtables with severity/category/owner/message/topic.
function Write-ValidatorReport {
    param(
        [string]$RunId,
        [ValidateSet('coverage', 'plan')][string]$Report,
        [string[]]$Mandatory = (Get-MandatoryTopics),
        [hashtable]$Statuses = @{},
        [object[]]$Findings = @(),
        [string]$Verdict,
        [switch]$NoSummary
    )
    $blocking = @($Findings | Where-Object { $_.severity -eq 'blocking' })
    if (-not $Verdict) { $Verdict = if ($blocking.Count) { 'fail' } else { 'pass' } }
    $obj = [ordered]@{
        report           = $Report
        run_id           = $RunId
        generated_by     = 'quality-validator'
        verdict          = $Verdict
        mandatory_topics = @($Mandatory | ForEach-Object { [ordered]@{ topic = $_; status = $(if ($Statuses[$_]) { $Statuses[$_] } else { 'covered' }); evidence = 'section present' } })
        findings         = @($Findings)
        optional_recommendations = @('ASP.NET Core Web APIs review')
    }
    $dir = Join-Path (Get-RunDir $RunId) 'validation'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir "$Report.json") -Encoding utf8NoBOM
    if (-not $NoSummary) { "# Validation: $Report`n`nVerdict: $Verdict" | Set-Content -LiteralPath (Join-Path $dir "$Report.md") -Encoding utf8NoBOM }
}

function New-Finding([string]$Owner, [string]$Message, [string]$Severity = 'blocking', [string]$Category = 'missing_coverage', [string]$Topic) {
    $f = [ordered]@{ id = "F$([guid]::NewGuid().ToString('N').Substring(0, 4))"; severity = $Severity; category = $Category; owner = $Owner; message = $Message; fix = 'Fix it.' }
    if ($Topic) { $f.topic = $Topic }
    $f
}

# A plan.md that passes the deterministic gate unless told otherwise.
function Get-PlanText {
    param(
        [string[]]$Areas = @('dotnet', 'data', 'architecture'),
        [string[]]$Mandatory = (Get-MandatoryTopics $Areas),
        [string]$Budget = '15',
        [int]$SessionMinutes = 60,
        [string[]]$OmitTopics = @(),
        [string]$ExtraUrl,
        [string]$PlannedHours
    )
    $topics = @($Mandatory | Where-Object { $OmitTopics -notcontains $_ })
    $url = 'https://learn.microsoft.com/dotnet/a'
    $rows = @(); $n = 0
    foreach ($t in $topics) {
        $rows += "| $(++$n) | 1 | $t | theory, practice | $SessionMinutes | $url |"
        $rows += "| $(++$n) | 2 | $t | interview | $SessionMinutes | $url |"
    }
    $rows += "| $(++$n) | 3 | All topics | revision, mock | $SessionMinutes | $url |"
    $total = [math]::Round($n * $SessionMinutes / 60, 2)
    if (-not $PlannedHours) { $PlannedHours = "$total" }
    $lines = @('---', 'artifact: plan', 'generated_by: study-planner', "budget_hours: $Budget", "planned_hours: $PlannedHours", 'research_inputs:')
    $lines += @($Areas | ForEach-Object { "  - research/$_.md" })
    $lines += @('---', '', '# Study Plan: Senior .NET backend', '', '## Summary', 'Plan.', '', '## Assumptions', '- Latest LTS .NET.', '',
        '## Time Budget', "$total of $Budget hours.", '', '## Schedule', '| # | Week | Topic | Activities | Minutes | Sources |', '|---|---|---|---|---|---|')
    $lines += $rows
    $lines += @('', '## Topic Plans', '')
    foreach ($t in $topics) { $lines += @("### $t", "- Theory: read [docs]($url).", '- Practice: exercise.', '- Interview: questions.', '') }
    $lines += @('## Revision and Mock Interviews', 'Week 3 mock.', '', '## Sources', "- Docs: $url")
    if ($ExtraUrl) { $lines += "- Extra: $ExtraUrl" }
    $lines += @('', '## Optional Extensions', '- ASP.NET Core Web APIs review.')
    $lines -join "`n"
}

function Write-Plan([string]$RunId, [string]$Text) {
    Set-Content -LiteralPath (Join-Path (Get-RunDir $RunId) 'plan.md') -Value $Text -Encoding utf8NoBOM -NoNewline
}

# Drives a run through a passing coverage gate.
function Complete-Coverage([string]$RunId, [string[]]$Areas = @('dotnet', 'data', 'architecture')) {
    Assert-Ok (Invoke-State @('start', '-RunId', $RunId, '-Step', 'coverage')) | Out-Null
    Write-ValidatorReport -RunId $RunId -Report coverage -Mandatory (Get-MandatoryTopics $Areas)
    Assert-Ok (Invoke-State @('complete', '-RunId', $RunId, '-Step', 'coverage', '-AgentId', 'validator-1')) | Out-Null
}

function Complete-Plan([string]$RunId, [string[]]$Areas = @('dotnet', 'data', 'architecture')) {
    Assert-Ok (Invoke-State @('start', '-RunId', $RunId, '-Step', 'plan')) | Out-Null
    Write-Plan $RunId (Get-PlanText -Areas $Areas)
    Assert-Ok (Invoke-State @('complete', '-RunId', $RunId, '-Step', 'plan', '-AgentId', 'planner-1')) | Out-Null
}

# No lock file and no temp files may be left in a run directory after operations finish.
function Assert-NoLeftovers([string]$RunId) {
    $dir = Get-RunDir $RunId
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dir 'state.lock'))) "orphaned state.lock in $dir"
    $tmp = @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp-*' -File -Recurse)
    Assert-Equal 0 $tmp.Count "orphaned temp files: $($tmp.Name -join ', ')"
}

function Assert-StateJsonValid([string]$RunId) {
    $raw = Get-Content -LiteralPath (Join-Path (Get-RunDir $RunId) 'state.json') -Raw
    try { $raw | ConvertFrom-Json -AsHashtable | Out-Null } catch { throw "state.json is not valid JSON: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- concurrent processes

# Launches one OS process per operation. Each process loads state.ps1's dependencies, signals
# readiness, and waits on a shared "go" file, so all operations start within milliseconds of
# each other. Returns one result per operation (exit code, output, timestamps, and whether
# state.json parsed right after that operation completed).
function Invoke-Concurrent {
    param(
        [Parameter(Mandatory)][hashtable[]]$Operations,
        [string]$StateScript = $script:StateScript,
        [int]$Readers = 0
    )
    $gate = Join-Path $script:TestRoot "gate-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $gate | Out-Null
    $goFile = Join-Path $gate 'go'
    $stopFile = Join-Path $gate 'stop'
    $worker = Join-Path $PSScriptRoot 'helpers/gated-worker.ps1'
    $reader = Join-Path $PSScriptRoot 'helpers/json-reader.ps1'

    $procs = @()
    $i = 0
    foreach ($op in $Operations) {
        $i++
        $argsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($op | ConvertTo-Json -Compress)))
        $procs += Start-PwshProcess $worker @('-StateScript', $StateScript, '-RunsRoot', $script:RunsRoot, '-GoFile', $goFile,
            '-ReadyFile', (Join-Path $gate "ready-$i"), '-ArgsBase64', $argsB64)
    }
    $readerProcs = @()
    for ($r = 1; $r -le $Readers; $r++) {
        $runId = $Operations[0].RunId
        $readerProcs += Start-PwshProcess $reader @('-StatePath', (Join-Path (Get-RunDir $runId) 'state.json'), '-GoFile', $goFile,
            '-StopFile', $stopFile, '-ReadyFile', (Join-Path $gate "reader-ready-$r"))
    }

    $expectedReady = $Operations.Count + $Readers
    $deadline = (Get-Date).AddSeconds(60)
    while (@(Get-ChildItem -LiteralPath $gate -Filter '*ready-*').Count -lt $expectedReady) {
        if ((Get-Date) -gt $deadline) { throw 'Concurrent workers did not become ready within 60 s.' }
        Start-Sleep -Milliseconds 20
    }
    New-Item -ItemType File -Path $goFile | Out-Null

    $results = foreach ($p in $procs) {
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'Concurrent worker timed out.' }
        $out = $p.StandardOutput.ReadToEnd()
        $line = ($out -split "`r?`n" | Where-Object { $_ -like '{*' } | Select-Object -Last 1)
        if (-not $line) { throw "Worker produced no result. Output: $out $($p.StandardError.ReadToEnd())" }
        $line | ConvertFrom-Json -AsHashtable
    }
    New-Item -ItemType File -Path $stopFile -Force | Out-Null
    $readerResults = foreach ($p in $readerProcs) {
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'Reader timed out.' }
        ($p.StandardOutput.ReadToEnd() -split "`r?`n" | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable
    }
    [pscustomobject]@{ Results = @($results); Readers = @($readerResults) }
}

function Start-PwshProcess([string]$Script, [string[]]$Arguments) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $Script) + $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    [System.Diagnostics.Process]::Start($psi)
}

# True if every operation's execution interval overlaps every other's (max start < min end).
function Get-Overlap($Results) {
    # ConvertFrom-Json may already have turned the ISO strings into DateTime values.
    $toDate = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime() } else { [datetime]::Parse($v, $null, 'RoundtripKind').ToUniversalTime() } }
    $starts = $Results | ForEach-Object { & $toDate $_.start }
    $ends = $Results | ForEach-Object { & $toDate $_.end }
    $maxStart = ($starts | Measure-Object -Maximum).Maximum
    $minStart = ($starts | Measure-Object -Minimum).Minimum
    $minEnd = ($ends | Measure-Object -Minimum).Minimum
    [pscustomobject]@{
        StartSpreadMs = ($maxStart - $minStart).TotalMilliseconds
        AllOverlap    = $maxStart -lt $minEnd
    }
}
