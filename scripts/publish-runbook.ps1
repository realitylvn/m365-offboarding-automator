<#
.SYNOPSIS
  Push runbook/Invoke-Offboarding.ps1 into the Automation Account and publish it.

.DESCRIPTION
  Bicep creates the runbook resource empty and unpublished - PowerShell source is
  never carried in the template. This script uploads the current file content as
  the draft and publishes it. Idempotent: each run replaces the draft and
  re-publishes, so it is safe from the azd postprovision hook and from CI.

.PARAMETER ResourceGroupName
  Resource group holding the Automation Account.

.PARAMETER AutomationAccountName
  Automation Account name.

.PARAMETER RunbookName
  Runbook resource name. Must match the name Bicep created.

.PARAMETER RunbookPath
  Path to the runbook source file to publish.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Runs from the azd postprovision hook and CI; progress is meant for the console.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$AutomationAccountName,
    [string]$RunbookName = 'Invoke-Offboarding',
    [string]$RunbookPath = "$PSScriptRoot/../runbook/Invoke-Offboarding.ps1"
)

$ErrorActionPreference = 'Stop'

$resolvedPath = (Resolve-Path -LiteralPath $RunbookPath).Path
Write-Host "Publishing '$RunbookName' to $AutomationAccountName (rg: $ResourceGroupName)"
Write-Host "  source: $resolvedPath"

# The 'automation' command group ships in an az CLI extension.
az automation runbook show --help *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  installing az CLI 'automation' extension"
    az extension add --name automation --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Failed to add the az CLI 'automation' extension." }
}

az automation runbook replace-content `
    --resource-group $ResourceGroupName `
    --automation-account-name $AutomationAccountName `
    --name $RunbookName `
    --content "@$resolvedPath"
if ($LASTEXITCODE -ne 0) { throw "az automation runbook replace-content failed (exit $LASTEXITCODE)." }

az automation runbook publish `
    --resource-group $ResourceGroupName `
    --automation-account-name $AutomationAccountName `
    --name $RunbookName
if ($LASTEXITCODE -ne 0) { throw "az automation runbook publish failed (exit $LASTEXITCODE)." }

$state = az automation runbook show `
    --resource-group $ResourceGroupName `
    --automation-account-name $AutomationAccountName `
    --name $RunbookName `
    --query 'state' -o tsv
if ($LASTEXITCODE -ne 0) { throw "az automation runbook show failed (exit $LASTEXITCODE)." }

Write-Host "  published. runbook state: $state"
