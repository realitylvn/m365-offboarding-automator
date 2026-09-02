<#
.SYNOPSIS
  On-demand M365 offboarding for a single target user.
.DESCRIPTION
  Runs as an Azure Automation runbook. Authenticates to Microsoft Graph as the
  Automation Account's system-assigned Managed Identity, then performs four
  independently-wrapped, partial-completion-tolerant steps:
    1. Disable the account
    2. Revoke all sign-in sessions
    3. Remove all license assignments
    4. Remove all manually-assigned group memberships (dynamic groups skipped)
  Emits a structured log line per step and a final JSON summary as job output.
.PARAMETER TargetUpn
  User principal name of the account to offboard.
.PARAMETER LoadFunctionsOnly
  Test hook: dot-source the file to load its functions without executing the run.
#>
param(
    [Parameter(Mandatory)]
    [string]$TargetUpn,

    [switch]$LoadFunctionsOnly
)

function Write-RunLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $ts = [DateTime]::UtcNow.ToString('o')
    Write-Output ("[{0}] {1} {2}" -f $ts, $Level, $Message)
}

function New-StepResult {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][ValidateSet('succeeded', 'failed', 'skipped', 'noop')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Detail
    )
    [pscustomobject]@{
        Step         = $Step
        Status       = $Status
        Message      = $Message
        Detail       = $Detail
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-RunSummary {
    param(
        [Parameter(Mandatory)][string]$TargetUpn,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Results
    )
    $counts = @{ succeeded = 0; failed = 0; skipped = 0; noop = 0 }
    foreach ($r in $Results) { $counts[$r.Status]++ }
    [pscustomobject]@{
        TargetUpn       = $TargetUpn
        RunTimestampUtc = [DateTime]::UtcNow.ToString('o')
        Counts          = $counts
        Steps           = $Results
        OverallStatus   = if ($counts.failed -gt 0) { 'completed_with_failures' } else { 'completed' }
    }
}

function Resolve-TargetUser {
    param([Parameter(Mandatory)][string]$Upn)
    try {
        return Get-MgUser -UserId $Upn -Property 'id', 'userPrincipalName', 'accountEnabled' -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -match 'Request_ResourceNotFound|does not exist|ResourceNotFound|\bNotFound\b') {
            return $null
        }
        throw
    }
}

# --- step functions added in Tasks 6-9 ---
# --- Invoke-Offboarding orchestrator added in Task 10 ---

if (-not $LoadFunctionsOnly) {
    $ErrorActionPreference = 'Stop'
    Write-RunLog -Message "Runbook invoked for $TargetUpn. Orchestrator wiring is added in a later task."
    # Body filled in Task 10.
}
