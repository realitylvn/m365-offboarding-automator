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

$ErrorActionPreference = 'Stop'

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

function Disable-TargetAccount {
    param([Parameter(Mandatory)][pscustomobject]$User)
    $step = 'disable-account'
    if ($User.AccountEnabled -eq $false) {
        Write-RunLog -Message "Account $($User.UserPrincipalName) is already disabled." -Level 'INFO'
        return New-StepResult -Step $step -Status 'noop' -Message 'Account was already disabled.'
    }
    Update-MgUser -UserId $User.Id -AccountEnabled:$false
    Write-RunLog -Message "Disabled account $($User.UserPrincipalName)."
    return New-StepResult -Step $step -Status 'succeeded' -Message 'Account disabled.' -Detail @{ userId = $User.Id }
}

function Revoke-TargetSessions {
    param([Parameter(Mandatory)][pscustomobject]$User)
    Revoke-MgUserSignInSession -UserId $User.Id
    Write-RunLog -Message "Revoked all sign-in sessions for $($User.UserPrincipalName)."
    return New-StepResult -Step 'revoke-sessions' -Status 'succeeded' -Message 'All refresh tokens invalidated.' -Detail @{ userId = $User.Id }
}

function Remove-TargetLicenses {
    param([Parameter(Mandatory)][pscustomobject]$User)
    $step = 'remove-licenses'
    $details = @(Get-MgUserLicenseDetail -UserId $User.Id -All)
    if ($details.Count -eq 0) {
        Write-RunLog -Message "$($User.UserPrincipalName) has no direct license assignments." -Level 'INFO'
        return New-StepResult -Step $step -Status 'noop' -Message 'No licenses assigned.'
    }
    $skuIds = $details.SkuId
    Set-MgUserLicense -UserId $User.Id -AddLicenses @() -RemoveLicenses @($skuIds)
    Write-RunLog -Message ("Removed {0} license(s) from {1}: {2}" -f $skuIds.Count, $User.UserPrincipalName, ($details.SkuPartNumber -join ', '))
    return New-StepResult -Step $step -Status 'succeeded' -Message "Removed $($skuIds.Count) license assignment(s)." -Detail @{ removedSkus = @($skuIds) }
}

function Remove-TargetGroupMemberships {
    param([Parameter(Mandatory)][pscustomobject]$User)
    $step = 'remove-group-memberships'
    $removed = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()

    $memberships = @(Get-MgUserMemberOf -UserId $User.Id -All)
    $groups = $memberships | Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' }

    foreach ($g in $groups) {
        $ap = $g.AdditionalProperties
        $isDynamic = ($ap['groupTypes'] -contains 'DynamicMembership') -or ($null -ne $ap['membershipRuleProcessingState'])
        if ($isDynamic) {
            Write-RunLog -Message "Skipping dynamic group '$($ap['displayName'])' ($($g.Id)) - membership is rule-driven." -Level 'WARN'
            $skipped.Add($g.Id)
            continue
        }
        try {
            Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $User.Id
            Write-RunLog -Message "Removed $($User.UserPrincipalName) from group '$($ap['displayName'])' ($($g.Id))."
            $removed.Add($g.Id)
        }
        catch {
            Write-RunLog -Message "Failed to remove from group '$($ap['displayName'])' ($($g.Id)): $($_.Exception.Message)" -Level 'ERROR'
            $failed.Add($g.Id)
        }
    }

    $detail = @{ removed = $removed.ToArray(); skippedDynamic = $skipped.ToArray(); failed = $failed.ToArray() }
    if ($failed.Count -gt 0) {
        return New-StepResult -Step $step -Status 'failed' -Message "Removed $($removed.Count), failed $($failed.Count), skipped $($skipped.Count) dynamic." -Detail $detail
    }
    if ($removed.Count -eq 0) {
        return New-StepResult -Step $step -Status 'skipped' -Message "No manually-assigned groups to remove ($($skipped.Count) dynamic skipped)." -Detail $detail
    }
    return New-StepResult -Step $step -Status 'succeeded' -Message "Removed from $($removed.Count) group(s); skipped $($skipped.Count) dynamic." -Detail $detail
}

function Invoke-Offboarding {
    param(
        [Parameter(Mandatory)][string]$TargetUpn,
        [switch]$SkipConnect
    )

    if (-not $SkipConnect) {
        Connect-MgGraph -Identity -NoWelcome
        Write-RunLog -Message 'Connected to Microsoft Graph as the Automation Account managed identity.'
    }

    Write-RunLog -Message "Starting offboarding for $TargetUpn."
    $user = Resolve-TargetUser -Upn $TargetUpn
    if ($null -eq $user) {
        Write-RunLog -Message "User $TargetUpn not found. No actions taken." -Level 'ERROR'
        $summary = Get-RunSummary -TargetUpn $TargetUpn -Results @(
            New-StepResult -Step 'resolve-user' -Status 'failed' -Message 'Target UPN does not exist in the tenant.'
        )
        Write-Output ($summary | ConvertTo-Json -Depth 6)
        return $summary
    }

    $plan = [ordered]@{
        'disable-account'          = { Disable-TargetAccount -User $user }
        'revoke-sessions'          = { Revoke-TargetSessions -User $user }
        'remove-licenses'          = { Remove-TargetLicenses -User $user }
        'remove-group-memberships' = { Remove-TargetGroupMemberships -User $user }
    }

    $results = @()
    foreach ($stepName in $plan.Keys) {
        try {
            $results += & $plan[$stepName]
        }
        catch {
            Write-RunLog -Message "Step '$stepName' failed: $($_.Exception.Message)" -Level 'ERROR'
            $results += New-StepResult -Step $stepName -Status 'failed' -Message $_.Exception.Message
        }
    }

    $summary = Get-RunSummary -TargetUpn $TargetUpn -Results $results
    Write-RunLog -Message ("Done. succeeded={0} failed={1} skipped={2} noop={3}" -f `
            $summary.Counts.succeeded, $summary.Counts.failed, $summary.Counts.skipped, $summary.Counts.noop)
    Write-Output ($summary | ConvertTo-Json -Depth 6)
    return $summary
}

if (-not $LoadFunctionsOnly) {
    Invoke-Offboarding -TargetUpn $TargetUpn | Out-Null
}
