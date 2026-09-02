targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment; used for the resource group name and a short unique resource token.')
param environmentName string

@minLength(1)
@description('Azure region for all resources.')
param location string

@minValue(7)
@maxValue(730)
@description('Retention in days for the Log Analytics workspace that stores runbook job logs.')
param logRetentionDays int = 30

var tags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    logRetentionDays: logRetentionDays
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AUTOMATION_ACCOUNT_NAME string = resources.outputs.automationAccountName
output AUTOMATION_MI_PRINCIPAL_ID string = resources.outputs.automationMiPrincipalId
output RUNBOOK_NAME string = resources.outputs.runbookName
output LOG_ANALYTICS_WORKSPACE_NAME string = resources.outputs.logAnalyticsWorkspaceName
