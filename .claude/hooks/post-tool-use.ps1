#Requires -Version 7.0
# PostToolUse hook (CLAUDE.md §12.3). After a file write under runs/, or a shell command while
# runs are open, it checks the affected runs with the read-only, lock-free
# `state.ps1 ledger-status`, which recomputes every passed artifact's hash from disk. Only a
# violation that state.json has not recorded yet is recorded, with `state.ps1 verify` (which
# blocks the run). A clean check, or an already recorded violation, writes nothing, so a hook
# run never refreshes updated_at. It never repairs, restores, moves, or deletes a file, and it
# cannot undo the tool call.
param([string]$ProjectDir, [string]$RunsRoot, [string]$StateScript)
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    Initialize-HookContext $ProjectDir $RunsRoot $StateScript
    $in = Read-HookInput
    $tool = "$($in['tool_name'])"
    $ti = $in['tool_input']
    $runs = @()
    if ($tool -in 'Write', 'Edit', 'MultiEdit', 'NotebookEdit') {
        $path = "$(if ($ti['file_path']) { $ti['file_path'] } else { $ti['notebook_path'] })"
        if ($path) {
            $full = [System.IO.Path]::GetFullPath($path, $(if ($in['cwd']) { "$($in['cwd'])" } else { $script:ProjectDir }))
            $inRuns = Get-RelativeInside $script:RunsRoot $full
            if ($inRuns) { $runs = @(($inRuns -split '/')[0]) }
        }
    }
    elseif ($tool -in 'Bash', 'PowerShell') {
        $runs = @(Get-OpenRuns | ForEach-Object { $_.RunId })
    }

    $messages = foreach ($runId in $runs) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:RunsRoot $runId 'state.json') -PathType Leaf)) { continue }
        # Read-only first: ledger-status recomputes artifact hashes from disk and writes nothing.
        $check = Invoke-StateScript @('ledger-status', '-RunId', $runId)
        if ($check.ExitCode -ne 0 -or -not $check.Json) {
            [pscustomobject]@{ Kind = 'failure'; Text = "run ${runId}: $(("$($check.Stderr) $($check.Stdout)" -replace '\x1b\[[0-9;]*m', '').Trim())" }
            continue
        }
        $found = @(@($check.Json.blockers) | Where-Object { "$_" -like 'integrity violation:*' } | ForEach-Object { "$_".Substring('integrity violation:'.Length).Trim() })
        if ($found.Count -eq 0) { continue }
        $state = Read-RunStateFile $runId
        $recorded = @(if ($state['integrity'] -and $state['integrity']['status'] -eq 'violated') { @($state['integrity']['violations']) | ForEach-Object { "$($_['step'])" } })
        if (@($found | Where-Object { $_ -notin $recorded }).Count -eq 0) {
            [pscustomobject]@{ Kind = 'violation'; Text = "run ${runId}: integrity violation already recorded ($($found -join ', ')); the run stays blocked until it is resolved." }
            continue
        }
        # A new violation: record it with the existing mechanism (verify saves it and blocks the run).
        $r = Invoke-StateScript @('verify', '-RunId', $runId)
        if ($r.Json -and $r.Json.violations) { foreach ($v in $r.Json.violations) { [pscustomobject]@{ Kind = 'violation'; Text = "run ${runId}: $($v.message)" } } }
        else { [pscustomobject]@{ Kind = 'failure'; Text = "run ${runId}: recording the violation failed: $(("$($r.Stderr) $($r.Stdout)" -replace '\x1b\[[0-9;]*m', '').Trim())" } }
    }
    $violations = @($messages | Where-Object { $_.Kind -eq 'violation' } | ForEach-Object { $_.Text })
    $failures = @($messages | Where-Object { $_.Kind -eq 'failure' } | ForEach-Object { $_.Text })
    $parts = @()
    if ($violations.Count) { $parts += "Integrity violation after this tool call. The change is not accepted, the run is blocked, and nothing was repaired or deleted. $($violations -join ' ')" }
    if ($failures.Count) { $parts += "Integrity could not be checked after this tool call; nothing was recorded or changed for these runs. $($failures -join ' ')" }
    if ($parts.Count) { [ordered]@{ decision = 'block'; reason = ($parts -join ' ') } | ConvertTo-Json -Compress }
    exit 0
}
catch {
    [Console]::Error.WriteLine("post-tool-use hook failed: $($_.Exception.Message). Integrity was not checked; run 'pwsh -NoProfile -File scripts/state.ps1 verify -RunId <run>'.")
    exit 2
}
