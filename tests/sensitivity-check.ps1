#Requires -Version 7.0
# Negative control: runs the 12-process storm against a copy of state.ps1 whose lock is a
# no-op. If the concurrency tests are meaningful, this copy should show lost updates or
# double winners. Dot-sourced by run-tests.ps1 -SensitivityCheck; results are reported only.

Write-Section 'sensitivity check (locking disabled in a temporary copy of state.ps1)'
$unlocked = Join-Path $script:TestRoot 'state-unlocked.ps1'
$source = Get-Content -LiteralPath $script:StateScript -Raw
$patched = $source -replace 'function Enter-StateLock\(\[string\]\$RunDir\) \{', "function Enter-StateLock([string]`$RunDir) { return `$null"
if ($patched -eq $source) { throw 'Could not disable the lock in the copy; Enter-StateLock signature changed.' }
Set-Content -LiteralPath $unlocked -Value $patched -Encoding utf8NoBOM

$violations = 0
$rounds = [Math]::Max($Iterations, 5)
for ($n = 1; $n -le $rounds; $n++) {
    $id = New-SelectedRun
    $ops = foreach ($area in 'dotnet', 'data', 'architecture') { 1..4 | ForEach-Object { @{ Action = 'start'; RunId = $id; Step = "research-$area" } } }
    $b = Invoke-Concurrent -Operations $ops -StateScript $unlocked
    $s = $null
    try { $s = Read-RunState $id } catch { $violations++; continue }
    foreach ($area in 'dotnet', 'data', 'architecture') {
        $wins = @($b.Results | Where-Object { $_.step -eq "research-$area" -and $_.exit_code -eq 0 }).Count
        if ($wins -ne 1 -or $s.steps."research-$area".status -ne 'running' -or $s.steps."research-$area".attempts -ne 1) { $violations++ }
    }
    $violations += @($b.Results | Where-Object { -not $_.json_valid -or ($_.exit_code -ne 0 -and $_.error -notmatch 'already running') }).Count
}
Add-Note "without locking: $violations invariant violations in $rounds storm rounds (with locking the same scenario must have 0)"
