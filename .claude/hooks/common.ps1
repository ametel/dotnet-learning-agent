#Requires -Version 7.0
# Shared helpers for the dotnet-learning-agent hooks (CLAUDE.md §12). Dot-sourced by
# user-prompt-submit.ps1, pre-tool-use.ps1 and post-tool-use.ps1. Every hook is started by a
# hash-pinned launcher in .claude/settings.json (scripts/pin-hooks.ps1), so a changed hook
# file is detected before it runs.
#
# Hooks are guardrails inside Claude Code, not an OS security boundary: `!` commands, nested
# sessions started outside Claude Code, and anything else running as the same user are not
# seen by them.

$ErrorActionPreference = 'Stop'

# Workflow subagents and the one artifact each may write (CLAUDE.md §5).
$script:WorkflowAgents = @('requirements-formalizer', 'dotnet-researcher', 'data-researcher', 'architecture-researcher', 'quality-validator', 'study-planner')
# Run statuses after which a run no longer restricts the shell.
$script:ClosedStatuses = @('completed', 'rejected', 'failed')
# A run not updated for this long no longer restricts the shell (an abandoned run must not
# lock the repository forever).
$script:OpenRunWindowHours = 24
$script:PathComparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

function Initialize-HookContext([string]$ProjectDir, [string]$RunsRoot, [string]$StateScript) {
    if (-not $ProjectDir) { $ProjectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { Join-Path $PSScriptRoot '..' '..' } }
    $script:ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
    $script:RunsRoot = [System.IO.Path]::GetFullPath($(if ($RunsRoot) { $RunsRoot } else { Join-Path $script:ProjectDir 'runs' }))
    $script:StateScript = [System.IO.Path]::GetFullPath($(if ($StateScript) { $StateScript } else { Join-Path $script:ProjectDir 'scripts' 'state.ps1' }))
}

function Read-HookInput {
    $raw = [Console]::In.ReadToEnd()
    $in = $raw | ConvertFrom-Json -AsHashtable
    if ($in -isnot [System.Collections.IDictionary]) { throw 'Hook input is not a JSON object.' }
    return $in
}

function Get-Sha256([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

# Path of $Path relative to $Root with '/' separators, or $null if it is not inside $Root.
function Get-RelativeInside([string]$Root, [string]$Path) {
    $root = $Root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $Path.StartsWith($root, $script:PathComparison)) { return $null }
    $Path.Substring($root.Length).Replace('\', '/')
}

# True if any existing directory between $Root and $Path (inclusive) is a junction or symlink:
# a link inside a protected tree could point anywhere, so writes through it are refused.
function Test-LinkInPath([string]$Root, [string]$Path) {
    $current = $Path
    while ($current -and $current.Length -gt $Root.TrimEnd('\', '/').Length) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
        }
        $current = Split-Path -Path $current -Parent
    }
    return $false
}

function Read-RunStateFile([string]$RunId) {
    $path = Join-Path $script:RunsRoot $RunId 'state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $params = @{ AsHashtable = $true }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $params.DateKind = 'String' }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json @params
}

# Runs that restrict shell commands: not closed, and updated within the open-run window.
function Get-OpenRuns {
    if (-not (Test-Path -LiteralPath $script:RunsRoot -PathType Container)) { return , @() }
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-$script:OpenRunWindowHours)
    $open = foreach ($dir in Get-ChildItem -LiteralPath $script:RunsRoot -Directory) {
        try { $s = Read-RunStateFile $dir.Name } catch { $s = $null }
        if (-not $s -or $s['workflow_status'] -in $script:ClosedStatuses) { continue }
        $updated = [datetime]::MinValue
        if (-not [datetime]::TryParse("$($s['updated_at'])", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$updated)) { continue }
        if ($updated -ge $cutoff) { [pscustomobject]@{ RunId = $dir.Name; Status = $s['workflow_status'] } }
    }
    , @($open)
}

# Runs scripts/state.ps1 in a child process; returns exit code and parsed JSON output.
function Invoke-StateScript([string[]]$Arguments) {
    $output = & pwsh -NoProfile -NonInteractive -File $script:StateScript @Arguments -RunsRoot $script:RunsRoot 2>&1
    $code = $LASTEXITCODE
    $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
    $json = $null
    if ($stdout.Trim()) { try { $json = $stdout | ConvertFrom-Json -AsHashtable } catch { } }
    [pscustomobject]@{ ExitCode = $code; Json = $json; Stdout = $stdout; Stderr = $stderr }
}

# The per-run lock state.ps1 uses (FileShare.None, deleted on close).
function Enter-RunLock([string]$RunDir) {
    $path = Join-Path $RunDir 'state.lock'
    $deadline = (Get-Date).AddSeconds(15)
    while ($true) {
        try {
            return [System.IO.FileStream]::new($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ((Get-Date) -gt $deadline) { throw "Timed out waiting for state lock: $path" }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Write-TextFileAtomic([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tmp, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}

function Write-PreToolDecision([ValidateSet('deny', 'ask')][string]$Decision, [string]$Reason) {
    [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = $Decision; permissionDecisionReason = $Reason } } | ConvertTo-Json -Compress -Depth 5
}
