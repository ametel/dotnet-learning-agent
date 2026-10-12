#Requires -Version 7.0
# Concurrent unlocked reader: re-reads and parses state.json in a tight loop while writers
# run, and counts torn or invalid reads. Prints one JSON result line.
param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$GoFile,
    [Parameter(Mandatory)][string]$StopFile,
    [Parameter(Mandatory)][string]$ReadyFile
)
$ErrorActionPreference = 'Stop'
'{"a":1}' | ConvertFrom-Json -AsHashtable | Out-Null
New-Item -ItemType File -Path $ReadyFile | Out-Null
while (-not (Test-Path -LiteralPath $GoFile)) { [System.Threading.Thread]::Sleep(1) }

$reads = 0; $parseErrors = 0; $ioErrors = 0; $samples = @()
while (-not (Test-Path -LiteralPath $StopFile)) {
    try {
        $raw = [System.IO.File]::ReadAllText($StatePath)
        try { $raw | ConvertFrom-Json -AsHashtable | Out-Null; $reads++ }
        catch { $parseErrors++; if ($samples.Count -lt 3) { $samples += $raw.Substring(0, [Math]::Min(80, $raw.Length)) } }
    }
    catch [System.IO.IOException], [System.UnauthorizedAccessException] { $ioErrors++ }
}
[ordered]@{ reads = $reads; parse_errors = $parseErrors; io_errors = $ioErrors; samples = $samples } | ConvertTo-Json -Compress
