@description('Azure region for all resources.')
param location string
@description('azd environment name ("offboarding-dev"); drives every resource name per azure-naming-conventions.md.')
param environmentName string
@description('Tags applied to every resource.')
param tags object
@description('Retention in days for the Log Analytics workspace that stores runbook job logs.')
param logRetentionDays int

// Resource names follow "<caf-abbreviation>-<environmentName>". None of the
// resources here require a globally-unique name (no storage account, no Function
// App), so no azd uniqueness token is appended - the human-readable name stands.
var runbookName = 'Invoke-Offboarding'

// Graph SDK sub-modules the runbook imports. Microsoft.Graph.Authentication is
// imported first (below) because the rest take a runtime dependency on it.
var graphModules = [
  'Microsoft.Graph.Users'
  'Microsoft.Graph.Users.Actions'
  'Microsoft.Graph.Groups'
  'Microsoft.Graph.Identity.DirectoryManagement'
]

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${environmentName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
    workspaceCapping: {
      dailyQuotaGb: json('1')
    }
  }
}

resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: 'aa-${environmentName}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Free'
    }
    publicNetworkAccess: true
  }
}

resource graphAuthModule 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = {
  parent: automation
  name: 'Microsoft.Graph.Authentication'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication'
    }
  }
}

resource graphSubModules 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = [
  for m in graphModules: {
    parent: automation
    name: m
    properties: {
      contentLink: {
        uri: 'https://www.powershellgallery.com/api/v2/package/${m}'
      }
    }
    dependsOn: [
      graphAuthModule
    ]
  }
]

// Created empty and unpublished on purpose - content is pushed out-of-band by
// scripts/publish-runbook.ps1 (via the azd postprovision hook) so Bicep never
// carries runbook source.
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automation
  name: runbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: true
    logProgress: true
    description: 'On-demand M365 offboarding for a single target UPN. Content published out-of-band by scripts/publish-runbook.ps1.'
  }
}

resource automationDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: automation
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'JobLogs'
        enabled: true
      }
      {
        category: 'JobStreams'
        enabled: true
      }
    ]
  }
}

output automationAccountName string = automation.name
output automationMiPrincipalId string = automation.identity.principalId
output runbookName string = runbook.name
output logAnalyticsWorkspaceName string = logAnalytics.name
