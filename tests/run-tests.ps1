#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the scripts/state.ps1 test suite. No dependencies beyond PowerShell 7.

.EXAMPLE
    pwsh -NoProfile -File tests/run-tests.ps1                  # all tests
    pwsh -NoProfile -File tests/run-tests.ps1 -SkipConcurrency # sequential tests only
    pwsh -NoProfile -File tests/run-tests.ps1 -Iterations 25   # heavier concurrency stress
    pwsh -NoProfile -File tests/run-tests.ps1 -SensitivityCheck
    pwsh -NoProfile -File tests/run-tests.ps1 -SkipConcurrency -Filter 'approv|reject|evidence'
#>
[CmdletBinding()]
param(
    # Run only the tests whose name matches this regular expression.
    [string]$Filter,
    # Iterations per concurrency scenario.
    [int]$Iterations = 5,
    [switch]$SkipConcurrency,
    # Keep the temporary test directory for inspection.
    [switch]$KeepTestRoot,
    # Also run the storm scenario against a copy of state.ps1 with locking disabled, to show
    # that the concurrency tests detect lost updates. Reported only, not counted as a test.
    [switch]$SensitivityCheck
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StateTestKit.ps1')
Initialize-TestKit -StateScript (Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'state.ps1')).Path
$script:CaseFilter = $Filter
Write-Host "state.ps1 tests: temp root $script:TestRoot"

try {
    . (Join-Path $PSScriptRoot 'state.tests.ps1')
    . (Join-Path $PSScriptRoot 'state.synthesis.tests.ps1')
    . (Join-Path $PSScriptRoot 'state.revision.tests.ps1')
    . (Join-Path $PSScriptRoot 'state.approval.tests.ps1')
    if (-not $SkipConcurrency) { . (Join-Path $PSScriptRoot 'state.concurrency.tests.ps1') }
    if ($SensitivityCheck) { . (Join-Path $PSScriptRoot 'sensitivity-check.ps1') }
    $failed = Write-TestSummary
}
finally {
    if ($KeepTestRoot) { Write-Host "Kept $script:TestRoot" }
    else { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
exit ([int]($failed -gt 0))
