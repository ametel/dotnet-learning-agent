#Requires -Version 7.0
# One concurrent test worker = one OS process. It warms up, signals readiness, waits for the
# shared go file, runs a single state.ps1 operation, then checks that state.json parses.
# Prints one JSON result line.
param(
    [Parameter(Mandatory)][string]$StateScript,
    [Parameter(Mandatory)][string]$RunsRoot,
    [Parameter(Mandatory)][string]$GoFile,
    [Parameter(Mandatory)][string]$ReadyFile,
    [Parameter(Mandatory)][string]$ArgsBase64
)
$ErrorActionPreference = 'Stop'
$op = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgsBase64)) | ConvertFrom-Json -AsHashtable
$op.RunsRoot = $RunsRoot
$statePath = Join-Path $RunsRoot $op.RunId 'state.json'

# Warm up the cmdlets state.ps1 uses, so start-up cost doesn't spread the start times.
'{"a":1}' | ConvertFrom-Json -AsHashtable | ConvertTo-Json | Out-Null
Get-FileHash -LiteralPath $statePath -Algorithm SHA256 | Out-Null

New-Item -ItemType File -Path $ReadyFile | Out-Null
while (-not (Test-Path -LiteralPath $GoFile)) { [System.Threading.Thread]::Sleep(1) }

$start = [datetime]::UtcNow
$code = 0
$errorText = $null
$output = $null
try {
    # In-process call: the lock is released by state.ps1's finally block (see Phase 2C fix),
    # and this process exits right after, as a -File invocation would.
    $global:LASTEXITCODE = 0
    $output = (& $StateScript @op) -join "`n"
    $code = $LASTEXITCODE
}
catch {
    $code = 1
    $errorText = "$($_.Exception.Message)"
}
$end = [datetime]::UtcNow

# Valid JSON right after this operation completed (an unlocked read, like the Read tool's).
$jsonValid = $false
$jsonError = $null
for ($try = 0; $try -lt 20 -and -not $jsonValid; $try++) {
    try { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable | Out-Null; $jsonValid = $true }
    catch [System.IO.IOException] { $jsonError = "io: $($_.Exception.Message)"; Start-Sleep -Milliseconds 5 }
    catch { $jsonError = "parse: $($_.Exception.Message)"; break }
}

[ordered]@{
    action     = $op.Action
    step       = $op.Step
    exit_code  = $code
    output     = $output
    error      = $errorText
    start      = $start.ToString('o')
    end        = $end.ToString('o')
    json_valid = $jsonValid
    json_error = $jsonError
    pid        = $PID
} | ConvertTo-Json -Compress
