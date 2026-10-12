#Requires -Version 7.0
# Holds a run's state.lock with the same flags state.ps1 uses, for -HoldMs milliseconds.
# Used to test lock waiting, timeout, and recovery after the holder is killed.
param(
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][int]$HoldMs,
    [Parameter(Mandatory)][string]$ReadyFile
)
$fs = [System.IO.FileStream]::new($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
New-Item -ItemType File -Path $ReadyFile | Out-Null
Start-Sleep -Milliseconds $HoldMs
$fs.Dispose()
