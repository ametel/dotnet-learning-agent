#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the "hooks" section of .claude/settings.json: one launcher per hook event, each
    pinned to the SHA-256 of every file the hooks run (CLAUDE.md §12.4).

.DESCRIPTION
    Claude Code loads hook settings once, when a session starts, but runs the hook scripts
    from disk on every call. A script changed mid-session would therefore run unchecked. The
    launchers carry the expected hashes inside settings.json, so a changed file is detected:
    PreToolUse then denies every tool call, PostToolUse reports the failure, and
    UserPromptSubmit records nothing (the prompt itself still goes through).

    Run it yourself after changing any pinned file, then restart Claude Code. Inside a
    session, use `! pwsh -NoProfile -File scripts/pin-hooks.ps1`: hooks do not see `!`
    commands, and settings changes require your confirmation anyway.
    Only the "hooks" section is replaced; permissions and other settings are kept.

.EXAMPLE
    pwsh -NoProfile -File scripts/pin-hooks.ps1
    pwsh -NoProfile -File scripts/pin-hooks.ps1 -ProjectDir <scratch-project>   # test copies
#>
[CmdletBinding()]
param([string]$ProjectDir = (Join-Path $PSScriptRoot '..'))
$ErrorActionPreference = 'Stop'
$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)

$pinned = @(
    '.claude/hooks/common.ps1'
    '.claude/hooks/user-prompt-submit.ps1'
    '.claude/hooks/pre-tool-use.ps1'
    '.claude/hooks/post-tool-use.ps1'
    '.claude/hooks/approval-policy.json'
    'scripts/state.ps1'
    'scripts/render-guide.ps1'
    'scripts/resume-run.ps1'
)
$hashes = [ordered]@{}
foreach ($rel in $pinned) { $hashes[$rel] = (Get-FileHash -LiteralPath (Join-Path $ProjectDir $rel) -Algorithm SHA256).Hash }
$pinLines = ($hashes.Keys | ForEach-Object { "    '$_' = '$($hashes[$_])'" }) -join "`n"

# On a pin mismatch or a crash: PreToolUse/PostToolUse exit 2 (deny / report); UserPromptSubmit
# exits 0 without running the hook, so nothing is recorded and prompts still work.
function New-Launcher([string]$Script, [int]$FailCode) {
    $onFail = if ($FailCode -eq 2) { '[Console]::Error.WriteLine($msg); exit 2' } else {
        "@{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = `$msg } } | ConvertTo-Json -Compress; exit 0" }
    $source = @"
`$ErrorActionPreference = 'Stop'
try {
  `$root = `$env:CLAUDE_PROJECT_DIR
  `$pins = [ordered]@{
$pinLines
  }
  foreach (`$k in `$pins.Keys) {
    `$p = Join-Path `$root `$k
    if (-not (Test-Path -LiteralPath `$p -PathType Leaf) -or (Get-FileHash -LiteralPath `$p -Algorithm SHA256).Hash -ne `$pins[`$k]) {
      `$msg = "Hook integrity: `$k changed since the hooks were pinned, so the hook did not run. Run '! pwsh -NoProfile -File scripts/pin-hooks.ps1' and restart Claude Code."
      $onFail
    }
  }
  `$global:LASTEXITCODE = 0
  & (Join-Path `$root '.claude/hooks/$Script')
  if (`$LASTEXITCODE -notin 0, 2) { `$msg = "Hook $Script failed closed (exit `$LASTEXITCODE)."; $onFail }
  exit `$LASTEXITCODE
} catch { `$msg = "Hook $Script failed closed: `$_"; $onFail }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($source))
    "pwsh -NoProfile -NonInteractive -EncodedCommand $encoded"
}

$fileAndShell = 'Write|Edit|MultiEdit|NotebookEdit|Bash|PowerShell'
$hooks = [ordered]@{
    UserPromptSubmit = @([ordered]@{ hooks = @([ordered]@{ type = 'command'; command = (New-Launcher 'user-prompt-submit.ps1' 0); timeout = 60 }) })
    PreToolUse       = @([ordered]@{ matcher = $fileAndShell; hooks = @([ordered]@{ type = 'command'; command = (New-Launcher 'pre-tool-use.ps1' 2); timeout = 60 }) })
    PostToolUse      = @([ordered]@{ matcher = $fileAndShell; hooks = @([ordered]@{ type = 'command'; command = (New-Launcher 'post-tool-use.ps1' 2); timeout = 120 }) })
}

$settingsPath = Join-Path $ProjectDir '.claude' 'settings.json'
$settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
$out = [ordered]@{}
foreach ($k in $settings.Keys) { if ($k -ne 'hooks') { $out[$k] = $settings[$k] } }
$out.hooks = $hooks
$tmp = "$settingsPath.tmp-$([guid]::NewGuid().ToString('N'))"
[System.IO.File]::WriteAllText($tmp, ($out | ConvertTo-Json -Depth 20) + "`n", [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::Move($tmp, $settingsPath, $true)
[ordered]@{ settings = $settingsPath; pinned = $hashes } | ConvertTo-Json
