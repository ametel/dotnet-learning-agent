#Requires -Version 7.0
# PreToolUse hook (CLAUDE.md §12.2). Decides for file writes and shell commands:
#   - deny: protected workflow files (state, version history, approval evidence, the guide),
#     artifacts written by anyone but their owner while its step runs, session transcripts,
#     nested Claude Code sessions, encoded or dynamic shell commands, and shell commands that
#     name protected files; while a run is open, any shell command outside a narrow allowlist;
#   - ask: changes to hook, settings, command, agent, or script files;
#   - otherwise no decision, so Claude Code's normal permissions apply.
# Any internal error denies the call (exit 2).
param([string]$ProjectDir, [string]$RunsRoot, [string]$StateScript)
. (Join-Path $PSScriptRoot 'common.ps1')

# A run's files and who may write them. Returns $null (no objection) or a deny reason.
function Get-RunWriteProblem([string]$Inner, [string]$RunId, [string]$Agent) {
    $state = Read-RunStateFile $RunId
    if (-not $state) { return "runs/$RunId has no state.json; runs are created by 'state.ps1 init'." }
    $scriptOwned = $Inner -in 'state.json', 'state.lock', 'approval.json', 'guide.html' -or
        $Inner -match '^(versions|validation/history|revisions|approval)/'
    if ($scriptOwned) { return "runs/$RunId/$Inner is written only by state.ps1 or the hooks (approval evidence, state, and version history are never written directly)." }

    $steps = $state['steps']
    $coordinatorFile = @{ 'confirmed-input.md' = $true; 'research-selection.json' = $true; 'revision-request.json' = $true }
    if ($coordinatorFile.ContainsKey($Inner)) {
        if ($Agent) { return "runs/$RunId/$Inner belongs to the coordinator, not to '$Agent'." }
        if ($Inner -eq 'confirmed-input.md' -and ($steps['requirements'].status -ne 'pending' -or [int]$steps['requirements'].attempts -gt 0)) { return 'confirmed-input.md is fixed once the requirements step has started.' }
        if ($Inner -eq 'research-selection.json' -and $state['research']) { return 'research-selection.json is fixed once the selection is recorded.' }
        return $null
    }
    $owned = switch -Regex ($Inner) {
        '^requirements\.md$' { 'requirements' }
        '^plan\.md$' { 'plan' }
        '^validation/coverage\.(json|md)$' { 'coverage' }
        '^validation/plan\.(json|md)$' { 'plan-validation' }
        '^research/([a-z]+)\.md$' { "research-$($Matches[1])" }
        default { $null }
    }
    if (-not $owned) { return "runs/$RunId/$Inner is not an artifact of this workflow." }
    $entry = $steps[$owned]
    if (-not $entry) { return "Step '$owned' does not exist in run $RunId." }
    $owner = "$($entry['agent'])"
    if ($Agent -ne $owner) { return "runs/$RunId/$Inner belongs to '$owner'$(if ($Agent) { ", not '$Agent'" } else { '; the coordinator never writes it' })." }
    if ($entry['status'] -ne 'running') { return "runs/$RunId/$Inner may be written only while step '$owned' is running (it is $($entry['status']))." }
    return $null
}

function Get-FileDecision([string]$Path, [string]$Agent, [string]$Cwd) {
    if (-not $Path) { return @{ Decision = 'deny'; Reason = 'The tool call names no file path.' } }
    $full = [System.IO.Path]::GetFullPath($Path, $(if ($Cwd) { $Cwd } else { $script:ProjectDir }))
    $isWorkflowAgent = $Agent -in $script:WorkflowAgents

    $claudeProjects = Join-Path $HOME '.claude' 'projects'
    if ((Get-RelativeInside $claudeProjects $full) -and $full.EndsWith('.jsonl', $script:PathComparison)) {
        return @{ Decision = 'deny'; Reason = 'Session transcripts are evidence of where a prompt came from; they are never written by tools.' }
    }
    $inRuns = Get-RelativeInside $script:RunsRoot $full
    if ($null -ne $inRuns) {
        if (Test-LinkInPath $script:RunsRoot $full) { return @{ Decision = 'deny'; Reason = 'Writes through a junction or symbolic link inside runs/ are refused.' } }
        $parts = @($inRuns -split '/')
        if ($parts.Count -lt 2) { return @{ Decision = 'deny'; Reason = 'Only files inside a run directory belong to the workflow.' } }
        $problem = Get-RunWriteProblem (($parts | Select-Object -Skip 1) -join '/') $parts[0] $Agent
        if ($problem) { return @{ Decision = 'deny'; Reason = $problem } }
        return $null
    }
    $rel = Get-RelativeInside $script:ProjectDir $full
    if ($isWorkflowAgent) { return @{ Decision = 'deny'; Reason = "'$Agent' writes only its assigned artifact under runs/." } }
    if ($null -ne $rel -and $rel -match '^(\.claude/(settings(\.local)?\.json|hooks/|commands/|agents/)|scripts/)') {
        if ($Agent) { return @{ Decision = 'deny'; Reason = "Subagents cannot change workflow configuration or scripts ($rel)." } }
        return @{ Decision = 'ask'; Reason = "$rel controls the workflow or its hooks; it changes only with your confirmation. After editing a pinned file, run '! pwsh -NoProfile -File scripts/pin-hooks.ps1' and restart Claude Code." }
    }
    return $null
}

# Allowed while a run is open: state.ps1, the test runner, and read-only git, each without
# shell operators (no chaining, redirection, substitution, or variables).
$script:Word = '(-[A-Za-z]+|[A-Za-z0-9_./:=@,+\-]+|"[^"`$;&|<>()]*"|''[^''`$;&<>()]*'')'
$script:AllowedShell = @(
    "^pwsh -NoProfile -File scripts/state\.ps1 [a-z-]+( $script:Word)*$"
    "^pwsh -NoProfile -File scripts/render-guide\.ps1( $script:Word)*$"
    "^pwsh -NoProfile -File tests/run-tests\.ps1( $script:Word)*$"
    '^git (status|diff|log|show)( [A-Za-z0-9_./:=@,+\-~^]+)*$'
)

function Get-ShellDecision([string]$Command, [string]$Agent) {
    $c = "$Command".Trim()
    if ($Agent -in $script:WorkflowAgents) { return @{ Decision = 'deny'; Reason = "'$Agent' has no shell access in this workflow." } }
    foreach ($pattern in $script:AllowedShell) { if ($c -cmatch $pattern) { return $null } }
    if ($c -match '(^|[\s;&|(`"''])claude(\.exe|\.cmd|\.ps1)?(\s|$|[;&|)`"''])' -or $c -match 'npx\s+(\S+\s+)*@anthropic-ai/claude-code') {
        return @{ Decision = 'deny'; Reason = 'Nested Claude Code sessions are refused: they can skip this project''s hooks.' }
    }
    if ($c -match '(?i)\b(pwsh|powershell)(\.exe)?\b.*\s-(e|ec|en|enc|enco|encod|encode|encoded|encodedc|encodedco|encodedcom|encodedcomm|encodedcomma|encodedcomman|encodedcommand)(\s|$)' -or
        $c -match '(?i)\b(invoke-expression|iex)\b|\bFromBase64String\b') {
        return @{ Decision = 'deny'; Reason = 'Encoded or dynamically evaluated commands are refused.' }
    }
    if ($c -match '(?i)(approval[/\\]|approval\.json|approval-policy|decisions\.jsonl|state\.json|state\.lock|guide\.html|versions[/\\]|validation[/\\]history|revisions[/\\]|\.claude[/\\](hooks|settings|projects))') {
        return @{ Decision = 'deny'; Reason = 'The command names protected workflow files (state, history, approval evidence, guide, hooks, settings, or transcripts). Use state.ps1 for state changes.' }
    }
    $open = Get-OpenRuns
    if ($open.Count -gt 0) {
        $list = ($open | ForEach-Object { "$($_.RunId) ($($_.Status))" }) -join ', '
        return @{ Decision = 'deny'; Reason = "A workflow run is open: $list. Shell commands are limited to 'pwsh -NoProfile -File scripts/state.ps1 ...', 'pwsh -NoProfile -File tests/run-tests.ps1 ...', and read-only git (status, diff, log, show), with no shell operators. For anything else, the user can run it with '!'." }
    }
    return $null
}

try {
    Initialize-HookContext $ProjectDir $RunsRoot $StateScript
    $in = Read-HookInput
    $tool = "$($in['tool_name'])"
    $agent = "$($in['agent_type'])"
    $ti = $in['tool_input']
    $result = switch ($tool) {
        { $_ -in 'Write', 'Edit', 'MultiEdit' } { Get-FileDecision "$($ti['file_path'])" $agent "$($in['cwd'])" }
        'NotebookEdit' { Get-FileDecision "$($ti['notebook_path'])" $agent "$($in['cwd'])" }
        { $_ -in 'Bash', 'PowerShell' } { Get-ShellDecision "$($ti['command'])" $agent }
        default { $null }
    }
    if ($result) { Write-PreToolDecision $result.Decision $result.Reason }
    exit 0
}
catch {
    [Console]::Error.WriteLine("pre-tool-use hook failed closed: $($_.Exception.Message)")
    exit 2
}
