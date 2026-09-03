#Requires -Version 7
<#
.SYNOPSIS
  Builds the repo-root status.json the Ops Command Center dashboard reads for
  this project.
.DESCRIPTION
  Offboarding is an on-demand tool with no storage account (the $0 design), so
  its status snapshot is a committed file regenerated as one step of the demo
  ritual: run the job, pass its JSON summary here, commit the result. The
  dashboard fetches it from raw.githubusercontent.com; cadence is on-demand, so
  it is never marked stale on age alone.
.PARAMETER RunSummaryPath
  Path to a JSON file holding either one run-summary object (the Get-RunSummary
  output shape: TargetUpn, RunTimestampUtc, Counts, OverallStatus) or an object
  with a 'runs' array (docs/sample-run.json shape). For an array, the last run
  is used.
.PARAMETER OutputPath
  Where to write status.json. Defaults to the repo root.
.NOTES
  Contract: azure-ops-command-center/docs/status-contract.md
  (m365-offboarding-automator, cadence: on-demand). Offboarding emits only
  'ok' or 'error' - it is an action tool, not a detector, so no 'finding' state.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Run by hand as a demo-ritual step; the one line of progress is meant for the console.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunSummaryPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..' 'status.json')
)
$ErrorActionPreference = 'Stop'

$raw = Get-Content -Path $RunSummaryPath -Raw | ConvertFrom-Json
$run = if ($null -ne $raw.runs) { @($raw.runs)[-1] } else { $raw }

$overall = [string]$run.OverallStatus
$status = if ($overall -eq 'completed') { 'ok' } else { 'error' }

# Normalise to second-precision UTC with a Z suffix, matching the cross-project
# contract. Get-RunSummary emits round-trip ('o') format with a Z already.
$lastRun = ([datetimeoffset]$run.RunTimestampUtc).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
$now = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

$headline = if ($status -eq 'ok') {
    "Last offboard: $($run.TargetUpn) - completed"
}
else {
    "Last offboard: $($run.TargetUpn) - completed with failures"
}

$doc = [ordered]@{
    schema_version = 1
    project        = 'm365-offboarding-automator'
    cadence        = 'on-demand'
    generated_at   = $now
    last_run_at    = $lastRun
    status         = $status
    headline       = $headline
    detail         = [ordered]@{
        target  = [string]$run.TargetUpn
        overall = $overall
        steps   = [ordered]@{
            succeeded = [int]$run.Counts.succeeded
            failed    = [int]$run.Counts.failed
            skipped   = [int]$run.Counts.skipped
            noop      = [int]$run.Counts.noop
        }
    }
    repo_url       = 'https://github.com/realitylvn/m365-offboarding-automator'
}

$doc | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding utf8
Write-Host "Wrote $OutputPath (status: $status, last run: $lastRun)"
