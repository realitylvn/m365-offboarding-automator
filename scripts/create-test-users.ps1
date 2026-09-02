<#
.SYNOPSIS
  One-time, idempotent creation of synthetic offboarding test accounts and demo groups.

.DESCRIPTION
  Creates N disabled-password test users (obvious 'offboard-test-N@contoso.com'
  naming, never real personnel), one assigned (static) security group with all the
  test users as members, and assigns a free license SKU if one is available in the
  tenant. Every write is guarded by an existence check, so the script is safe to
  re-run.

  A dynamic (rule-based) demo group was intentionally left out: dynamic membership
  is an Entra ID P1 feature the target tenant does not license. The runbook's
  skip-dynamic-groups behaviour is exercised by the Pester suite instead.

  Run interactively by a directory admin. Delegated Graph consent is requested for
  exactly three scopes: User.ReadWrite.All, Group.ReadWrite.All, Organization.Read.All.

.PARAMETER Count
  Number of synthetic users to ensure exist. Default 3.

.PARAMETER UpnPrefix
  Local-part prefix for the synthetic UPNs.

.PARAMETER Domain
  Verified tenant domain for the synthetic UPNs.

.PARAMETER LicenseSkuPartNumber
  SkuPartNumber to assign to each test user when the tenant has a spare unit. FLOW_FREE
  by default because it is free and self-service in most tenants.

.PARAMETER StaticGroupName
  Display name of the assigned (static) demo group.

.PARAMETER WhatIfOnly
  Print the plan (planned UPNs and groups) and exit without connecting or writing.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Operator-facing one-time setup script; progress is meant for the console.')]
[CmdletBinding()]
param(
    [int]$Count = 3,
    [string]$UpnPrefix = 'offboard-test',
    [string]$Domain = 'contoso.onmicrosoft.com',
    [string]$LicenseSkuPartNumber = 'FLOW_FREE',
    [string]$StaticGroupName = 'Offboarding Demo - Static',
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

$plannedUsers = 1..$Count | ForEach-Object { "$UpnPrefix-$_@$Domain" }

if ($WhatIfOnly) {
    $rows = @()
    $rows += $plannedUsers | ForEach-Object { [pscustomobject]@{ Action = 'ensure-user'; Target = $_ } }
    $rows += [pscustomobject]@{ Action = 'ensure-static-group'; Target = $StaticGroupName }
    $rows += [pscustomobject]@{ Action = 'assign-license-if-available'; Target = $LicenseSkuPartNumber }
    Write-Host "WhatIfOnly - no connection made, no changes written. Planned actions:"
    $rows
    return
}

function New-RandomPassword {
    # 4 fixed class anchors + 16 random printable chars - enough for Entra complexity.
    $pool = (33..126 | Where-Object { $_ -ne 96 } | ForEach-Object { [char]$_ })
    'Aa1!' + (-join (1..16 | ForEach-Object { $pool | Get-Random }))
}

Connect-MgGraph -Scopes 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Organization.Read.All' | Out-Null
Write-Host "Connected to Microsoft Graph."

# --- users ---
$users = foreach ($i in 1..$Count) {
    $upn = "$UpnPrefix-$i@$Domain"
    $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  user exists: $upn"
        $existing | Select-Object -First 1
        continue
    }
    Write-Host "  creating user: $upn"
    New-MgUser -DisplayName "Offboard Test $i" `
        -UserPrincipalName $upn `
        -MailNickname "$UpnPrefix-$i" `
        -AccountEnabled:$true `
        -UsageLocation 'US' `
        -PasswordProfile @{ Password = (New-RandomPassword); ForceChangePasswordNextSignIn = $true }
}

# --- license (best-effort: only if the SKU exists with a spare unit) ---
$sku = Get-MgSubscribedSku -All | Where-Object { $_.SkuPartNumber -eq $LicenseSkuPartNumber } | Select-Object -First 1
if ($sku) {
    $free = [int]$sku.PrepaidUnits.Enabled - [int]$sku.ConsumedUnits
    if ($free -gt 0) {
        foreach ($u in $users) {
            Write-Host "  assigning $LicenseSkuPartNumber to $($u.UserPrincipalName)"
            Set-MgUserLicense -UserId $u.Id -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() | Out-Null
        }
    }
    else {
        Write-Host "  SKU $LicenseSkuPartNumber has no free units - skipping license assignment."
    }
}
else {
    Write-Host "  SKU $LicenseSkuPartNumber not present in tenant - skipping license assignment."
}

# --- static demo group + membership ---
# Assigned (not rule-based) security group: the runbook's group-removal step is
# meant to strip exactly this kind of membership. A dynamic counterpart was
# dropped from setup - dynamic membership needs Entra ID P1, which the target
# tenant does not license; the runbook's skip-dynamic path stays covered by the
# Pester suite (Invoke-Offboarding.Tests.ps1).
$staticGroup = Get-MgGroup -Filter "displayName eq '$StaticGroupName'" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($staticGroup) {
    Write-Host "  group exists: $StaticGroupName"
}
else {
    Write-Host "  creating group: $StaticGroupName"
    $staticGroup = New-MgGroup -DisplayName $StaticGroupName `
        -MailNickname 'offboarding-demo-static' `
        -Description 'Synthetic offboarding-automator demo group.' `
        -SecurityEnabled:$true `
        -MailEnabled:$false `
        -GroupTypes @()
}

$currentMembers = @(Get-MgGroupMember -GroupId $staticGroup.Id -All | ForEach-Object { $_.Id })
foreach ($u in $users) {
    if ($currentMembers -contains $u.Id) {
        Write-Host "  already a member of '$StaticGroupName': $($u.UserPrincipalName)"
        continue
    }
    Write-Host "  adding $($u.UserPrincipalName) to '$StaticGroupName'"
    New-MgGroupMember -GroupId $staticGroup.Id -DirectoryObjectId $u.Id
}

[pscustomobject]@{
    Users         = $users | ForEach-Object { [pscustomobject]@{ Id = $_.Id; UserPrincipalName = $_.UserPrincipalName } }
    StaticGroupId = $staticGroup.Id
} | Format-List
