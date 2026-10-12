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

function Get-RequirementsText([int]$Blocking = 0, [string[]]$OmitHeadings = @(), [string]$BlockingValue) {
    $value = if ($PSBoundParameters.ContainsKey('BlockingValue')) { $BlockingValue } else { "$Blocking" }
    $lines = @('---', 'artifact: requirements', 'generated_by: requirements-formalizer', "blocking_open_questions: $value", '---', '')
    foreach ($h in $script:RequirementsHeadings) { if ($OmitHeadings -notcontains $h) { $lines += @($h, 'Content.', '') } }
    $lines -join "`n"
}

function Write-Requirements([string]$RunId, [string]$Text = (Get-RequirementsText)) {
    Set-Content -LiteralPath (Join-Path (Get-RunDir $RunId) 'requirements.md') -Value $Text -Encoding utf8NoBOM -NoNewline
}

# A run whose requirements step has passed.
function New-PassedRun([int]$Blocking = 0) {
    $id = New-Run
    Write-ConfirmedInput $id
    Assert-Ok (Invoke-State @('start', '-RunId', $id, '-Step', 'requirements')) | Out-Null
    Write-Requirements $id (Get-RequirementsText -Blocking $Blocking)
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
    $selected = @(); $notSelected = @()
    foreach ($area in $script:DefaultTopics.Keys) {
        if ($Areas -contains $area) { $selected += @{ agent = $script:AgentByArea[$area]; topics = $script:DefaultTopics[$area]; reason = "Gap in $area." } }
        else { $notSelected += @{ agent = $script:AgentByArea[$area]; reason = "No $area gap." } }
    }
    @{ selected = $selected; not_selected = $notSelected }
}

# A run with requirements passed and the given research areas selected.
function New-SelectedRun([string[]]$Areas = @('dotnet', 'data', 'architecture')) {
    $id = New-PassedRun
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
