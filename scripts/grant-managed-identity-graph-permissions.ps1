<#
.SYNOPSIS
  One-time, idempotent grant of the three Graph application permissions the
  offboarding runbook needs to the Automation Account's system-assigned managed identity.

.DESCRIPTION
  The runbook authenticates as the Automation Account's system-assigned managed
  identity (Connect-MgGraph -Identity). That identity's service principal must hold
  three Graph *application* app-role assignments (the admin-consent equivalent):
  User.ReadWrite.All, GroupMember.ReadWrite.All, Organization.Read.All - and no more.

  Run interactively by a Global Administrator / Privileged Role Administrator after
  the Automation Account exists. Delegated consent is requested for exactly
  Application.Read.All and AppRoleAssignment.ReadWrite.All. Safe to re-run: an
  assignment that already exists is left alone.

.PARAMETER AutomationAccountName
  Display name of the Automation Account; its system-assigned MI service principal
  shares this name. Used for the directory lookup unless -PrincipalId is given.

.PARAMETER ResourceGroupName
  Resource group of the Automation Account. Informational only - included in console
  output to disambiguate which account is being targeted.

.PARAMETER PrincipalId
  Object id of the managed-identity service principal. Pass this to skip the
  displayName lookup entirely (required when the name is ambiguous or not found).

.PARAMETER GraphPermissions
  The application permission values to grant. Defaults to the runbook's exact set;
  do not widen without updating the runbook and its review notes.

.PARAMETER WhatIfOnly
  Resolve and report the plan without writing any app-role assignment.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Operator-facing one-time setup script; progress is meant for the console.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AutomationAccountName,
    [string]$ResourceGroupName,
    [string]$PrincipalId,
    [string[]]$GraphPermissions = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Organization.Read.All'),
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$graphAppId = '00000003-0000-0000-c000-000000000000'

Connect-MgGraph -Scopes 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All' | Out-Null

$targetLabel = if ($ResourceGroupName) { "$AutomationAccountName (rg: $ResourceGroupName)" } else { $AutomationAccountName }
Write-Host "Target managed identity: $targetLabel"

# --- resolve the managed-identity service principal ---
if ($PrincipalId) {
    $miSp = Get-MgServicePrincipal -ServicePrincipalId $PrincipalId
}
else {
    $candidates = @(Get-MgServicePrincipal -Filter "displayName eq '$AutomationAccountName'" -All)
    if ($candidates.Count -ne 1) {
        throw "Expected exactly one service principal named '$AutomationAccountName', found $($candidates.Count). Re-run with -PrincipalId <managed identity object id> (Portal - Automation Account - Identity - System assigned - Object (principal) ID)."
    }
    $miSp = $candidates[0]
}
Write-Host "Resolved MI service principal: $($miSp.Id)"

# --- resolve the Microsoft Graph service principal (the resource holding the app roles) ---
$graphSp = @(Get-MgServicePrincipal -Filter "appId eq '$graphAppId'" -All)[0]
if (-not $graphSp) { throw "Could not resolve the Microsoft Graph service principal (appId $graphAppId) in this tenant." }

$existing = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miSp.Id -All)
$report = foreach ($perm in $GraphPermissions) {
    $role = $graphSp.AppRoles |
        Where-Object { $_.Value -eq $perm -and $_.AllowedMemberTypes -contains 'Application' } |
        Select-Object -First 1

    if (-not $role) {
        Write-Host "  [$perm] NOT-FOUND - no matching application app role on the Graph SP"
        [pscustomobject]@{ Permission = $perm; Action = 'NOT-FOUND' }
        continue
    }
    if ($existing.AppRoleId -contains $role.Id) {
        Write-Host "  [$perm] already assigned"
        [pscustomobject]@{ Permission = $perm; Action = 'already-present' }
        continue
    }
    if ($WhatIfOnly) {
        Write-Host "  [$perm] would grant (WhatIfOnly)"
        [pscustomobject]@{ Permission = $perm; Action = 'would-grant' }
        continue
    }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miSp.Id `
        -PrincipalId $miSp.Id -ResourceId $graphSp.Id -AppRoleId $role.Id | Out-Null
    Write-Host "  [$perm] granted"
    [pscustomobject]@{ Permission = $perm; Action = 'granted' }
}

$report | Format-Table -AutoSize
if (-not $WhatIfOnly) {
    Write-Host "Note: app-role assignments can take 10-20 minutes to propagate before the runbook can use them."
}
