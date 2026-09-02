# REVIEW.md — Build Log & Learning Notes

Personal study companion to this project. Unlike README.md (public/recruiter-facing),
this file tracks *why* each decision was made and logs every `az`/`azd`/Graph PowerShell
command as it runs, so the reasoning doesn't get reconstructed from memory after the fact.

## Why this approach

- **Managed Identity + app-role assignment instead of an app registration + certificate.**
  The original spec assumed two tenants (an M365 Developer Program tenant for the identity
  target, the LVN Azure subscription for compute) and therefore a cross-tenant app
  registration with a certificate credential. `az account show` confirmed the LVN Azure
  subscription's home tenant (`<TENANT_ID>`) *is* the contoso.onmicrosoft.com
  M365 tenant — one tenant, one subscription. That collapses the design: the Automation
  Account's own system-assigned Managed Identity is granted the three Graph *application*
  permissions it needs (`User.ReadWrite.All`, `GroupMember.ReadWrite.All`,
  `Organization.Read.All`) by direct app-role assignment, and the runbook authenticates with
  `Connect-MgGraph -Identity`. No app registration, no certificate, no stored secret of any
  kind — which also makes "Managed Identity, no stored secrets" true for every project in the
  portfolio, this one included.

- **Automation Account, not Functions.** The workload is an on-demand, human-triggered,
  parameterised administrative script with no HTTP surface and no schedule. Azure Automation
  runbooks are purpose-built for exactly that (operator kicks off a job with a `TargetUpn`
  parameter, job output and streams are captured automatically), and the Free SKU covers the
  expected volume. Functions would add an App Service plan, a trigger binding, and a storage
  account for nothing.

- **Runbook content published out-of-band, not embedded in Bicep.** The `runbooks` resource
  is created empty and unpublished; `scripts/publish-runbook.ps1` (wired to the `azd`
  `postprovision` hook) pushes `runbook/Invoke-Offboarding.ps1` and publishes it. Bicep never
  carries PowerShell source, and the runbook can be re-published from CI without a full
  `azd provision`.

- **Graph SDK sub-modules, not the meta-module.** Only `Microsoft.Graph.Authentication` plus
  the four sub-modules the runbook actually imports (`Users`, `Users.Actions`, `Groups`,
  `Identity.DirectoryManagement`) are imported into the Automation Account, with
  `Authentication` first because the others depend on it. Importing the full `Microsoft.Graph`
  meta-module pulls ~40 packages and is slow and failure-prone in Automation.

## Platform quirks hit along the way

### Naming & tagging convention — pre-flight correction (before any provision)

- **What the issue was.** The first-draft Bicep named every resource from an azd uniqueness
  token (`aa-${uniqueString(...)}`, `log-${uniqueString(...)}`), and the azd environment would
  have defaulted to the generic name `dev`. Across a five-project portfolio that produces
  resource groups and resources that are hard to tell apart at a glance and risk name
  collisions in shared views (cost analysis, the planned Ops Dashboard that queries across
  all four other projects).
- **Why it matters.** Microsoft's Cloud Adoption Framework prescribes a
  `<resource-type>-<workload>-<env>` human-readable naming pattern and a small set of
  governance tags precisely so multi-project estates stay navigable and queryable. This is
  also a legitimate AZ-104 "design governance" talking point, not busywork.
- **What changed.**
  - azd environment created as `offboarding-dev` from the start (`azd env new offboarding-dev`),
    never as the generic `dev` — so there was no old environment to migrate or delete.
  - Resource names now derive from `environmentName`: `rg-offboarding-dev`,
    `aa-offboarding-dev`, `log-offboarding-dev`. The uniqueness token was dropped entirely —
    none of this project's resources (no storage account, no Function App) require a
    globally-unique name.
  - `main.bicep` now stamps the resource group and, explicitly, every taggable resource with
    `portfolio: azure-devops-portfolio`, `project: offboarding`, `environment: dev` (Azure
    resources do not inherit resource-group tags without a policy). The Graph module child
    resources and the diagnostic-settings resource are untaggable by type — nothing to do
    there.
  - Verified with `az deployment sub what-if`: 10 resources to create, all names and tags as
    expected. Nothing provisioned yet — this was a checkpoint.

## CLI command log

| Command | What it did / why |
|---|---|
| `gh repo create realitylvn/m365-offboarding-automator --public --source=. --remote=origin --push` | Published the repo (public) and pushed the README scaffold, using the already-authenticated `gh` CLI rather than widening the GitHub MCP token (which returned 403 on repo creation). |
| `Invoke-RestMethod 'https://aka.ms/install-azd.ps1' \| Invoke-Expression` | Installed `azd` 1.32.0 (MSI, user-scoped) — not previously on PATH. |
| `Install-Module Pester -MinimumVersion 5.5.0 ...` / `Install-Module PSScriptAnalyzer` | Installed Pester 6.1.0 (bundled Windows Pester was 3.4.0, incompatible with the v5 config API the test harness uses) and PSScriptAnalyzer 1.25.0. |
| `az bicep build --file infra/main.bicep` / `az bicep lint` | Compiled and linted the template locally before any deployment — clean. |
| `az deployment sub validate --location eastus2 --template-file infra/main.bicep --parameters environmentName=dev location=eastus2` | Server-side template validation with nothing deployed — `Succeeded`. |
| `azd env new offboarding-dev --subscription <SUBSCRIPTION_ID> --location eastus2` | Created the azd environment with the portfolio-convention name from the start (`<slug>-<env>`), with subscription and region set explicitly so no generic-named environment ever existed. |
| `azd env get-values` | Confirmed `AZURE_ENV_NAME=offboarding-dev`, `AZURE_LOCATION=eastus2`, `AZURE_SUBSCRIPTION_ID` all set. |
| `az deployment sub what-if --location eastus2 --template-file infra/main.bicep --parameters environmentName=offboarding-dev location=eastus2` | Pre-provision checkpoint: showed the 10 resources that would be created with `rg-/aa-/log-offboarding-dev` names and the four governance tags on every taggable resource. **Stopped here — `azd provision` not yet run.** |
| `pwsh -File runbook/tests/Invoke-Pester.ps1` | Task 4 — ran the Pester 6.1.0 harness against the runbook scaffold (`Write-RunLog`, `New-StepResult`, `Get-RunSummary`): 6/6 pass, exit 0, `testResults.xml` (NUnit) written. |
| `Invoke-ScriptAnalyzer -Path runbook/Invoke-Offboarding.ps1 -Settings ./PSScriptAnalyzerSettings.psd1` | Linted production runbook — clean. Added `PSScriptAnalyzerSettings.psd1` (excludes `PSUseShouldProcessForStateChangingFunctions`; the factories/Graph wrappers don't need a `-WhatIf` surface). `runbook/tests/` is excluded from lint — the `GraphStubs.ps1` doubles carry named-but-unused params on purpose, as the Mock `-ParameterFilter` contract. |
| `pwsh -File runbook/tests/Invoke-Pester.ps1` | Tasks 5–10 — TDD for the whole runbook: `Resolve-TargetUser`, the four step functions, and the `Invoke-Offboarding` orchestrator. Ended at **20/20 pass**. `PSUseSingularNouns` added to the analyzer exclusions — `Revoke-TargetSessions` / `Remove-TargetLicenses` / `Remove-TargetGroupMemberships` act on whole collections and their names match the JSON summary step names. |
| `pwsh -File runbook/tests/Invoke-Pester.ps1` | Tasks 11–13 — TDD for the three setup scripts (`create-test-users.ps1`, `grant-managed-identity-graph-permissions.ps1`, `publish-runbook.ps1`). **34/34 pass.** Scripts only — none run against the tenant or Azure yet; CHECKPOINT 1/2/3 pending. |
| `pwsh -Command "Invoke-ScriptAnalyzer -Path <each> -Settings ./PSScriptAnalyzerSettings.psd1"` | Linted `runbook/Invoke-Offboarding.ps1` + `scripts/*.ps1` one file at a time — 0 findings each. (Passing an array to `-Path` throws `Cannot convert System.Object[] to String`; the CI job must loop per file.) `Write-Host` in the operator scripts is allowed via a file-scoped `[SuppressMessageAttribute('PSAvoidUsingWriteHost')]`. |
| `azd env get-values` | Re-confirmed `azure.yaml` still parses after adding the `postprovision` hook — `AZURE_ENV_NAME=offboarding-dev` etc. still resolve. |

## AZ-900 / AZ-104 domain mapping

- **Identity & access management**: system-assigned Managed Identity as a workload identity;
  Graph *application* permissions granted by app-role assignment (the admin-consent
  equivalent) vs. delegated consent; `revokeSignInSessions` and `accountEnabled` as account
  lifecycle operations. Core AZ-104 identity content.
- **Governance**: least-privilege Graph scoping (a hard three-permission ceiling), and the
  CAF naming + tagging convention applied before provisioning — both AZ-900 and AZ-104
  "design governance / manage subscriptions" material.
- **Automation & compute choice**: Automation Account vs. Functions trade-off for a
  no-trigger, on-demand administrative workload.
- **Monitoring**: Automation Account diagnostic settings routing `JobLogs` / `JobStreams` to
  a capped Log Analytics workspace — AZ-104 Azure Monitor coverage.
