// Stub module - real resources (Automation Account, Log Analytics, Graph modules,
// runbook, diagnostics) are added in Task 3. Parameters are declared now so
// main.bicep's module call is stable; `tags` and `logRetentionDays` are unused
// until Task 3 (Bicep emits a warning for these, not an error).

@description('Azure region for all resources.')
param location string
@description('azd environment name, used only to build the unique resource token.')
param environmentName string
@description('Tags applied to every resource.')
param tags object
@description('Retention in days for the Log Analytics workspace.')
param logRetentionDays int

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

output automationAccountName string = 'aa-${resourceToken}'
output automationMiPrincipalId string = ''
output runbookName string = 'Invoke-Offboarding'
output logAnalyticsWorkspaceName string = 'log-${resourceToken}'
