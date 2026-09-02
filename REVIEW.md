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
| `git push origin main` | Task 14 — pushed the 8 local-only commits (`6c84ef5`…`840c761`: runbook steps + orchestrator + setup scripts) that had been committed under the plan's authorisation but never pushed. Fast-forward, no PR — the code was already reviewed task-by-task. Done first so the CI PR would contain exactly one commit. |
| `git checkout -b ci-setup` / `gh pr create` / `gh pr checks 1 --watch` / `gh pr merge 1 --squash --delete-branch` | Task 14 — added `.github/workflows/ci.yml` (jobs `lint-ps`, `test-ps`, `bicep`) on branch `ci-setup`, opened PR #1, watched all three checks pass on GitHub-hosted runners, squash-merged to `main` (`566d98e`). First CI wiring. The `lint-ps` job loops `Invoke-ScriptAnalyzer -Path` one file at a time — passing the target array directly throws `Cannot convert System.Object[] to String`. `pull_request` + `push: branches-ignore:[main]` both fire on a PR branch, so a PR gets two identical runs (accepted, not worth a guard). |
| `Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.32.0 -Scope CurrentUser` | CHECKPOINT 1 pre-req — the local box had every `Microsoft.Graph.*` sub-module at 2.32.0 *except* `Microsoft.Graph.Authentication` (the core module that supplies `Connect-MgGraph`), so the setup script failed with "term 'Connect-MgGraph' is not recognized" until it was installed. |
| `pwsh -File scripts/create-test-users.ps1` | CHECKPOINT 1 — see *Checkpoint execution log → Stage 1* below. Interactive delegated sign-in (`User.ReadWrite.All`, `Group.ReadWrite.All`, `Organization.Read.All`). Partial success: 3 users + FLOW_FREE licenses + the static group created; the **dynamic group failed** (`400 NoLicenseForOperation` — dynamic membership needs Entra ID P1, which this tenant does not have). |
| `az deployment sub what-if --location eastus2 --template-file infra/main.bicep --parameters environmentName=offboarding-dev location=eastus2` | CHECKPOINT 3 pre-flight — 10 resources to create, names/tags as expected. |
| `azd provision --no-prompt` | CHECKPOINT 3 — first real provision. Deployment `offboarding-dev-1788325232` Succeeded: RG + Log Analytics + Automation Account + 5 Graph PS7.2 modules + published runbook + diagnostic setting. postprovision hook published the runbook. See *Stage 3* below. `azd`'s "reserved word MICROSOFT" pre-validation warning on the module resources is a false positive — deployment succeeded. |
| `az rest --method get .../powerShell72Modules?api-version=2023-11-01` / `.../runbooks/Invoke-Offboarding/content` / `.../diagnosticSettings` | CHECKPOINT 3 verification — the `az automation` CLI group is experimental and thin (`get-content` doesn't exist, `az monitor diagnostic-settings list` rejects the nested Automation id), so ARM REST via `az rest` was used to confirm module import state, published runbook content, and diagnostic routing. |
| `pwsh -File scripts/grant-managed-identity-graph-permissions.ps1 -AutomationAccountName aa-offboarding-dev -PrincipalId <PRINCIPAL_ID>` | CHECKPOINT 2 — granted the MI its 3 Graph application app-roles (`User.ReadWrite.All`, `GroupMember.ReadWrite.All`, `Organization.Read.All`) and no more. Global Admin session; consented the Graph CLI app to `Application.Read.All` + `AppRoleAssignment.ReadWrite.All`. See *Stage 2*. Needed `Microsoft.Graph.Applications` installed locally first. |
| `az rest --method get https://graph.microsoft.com/v1.0/servicePrincipals/<PRINCIPAL_ID>/appRoleAssignments` | CHECKPOINT 2 verification — confirmed exactly 3 assignments to the Graph SP, no extras. |

## Checkpoint execution log

### Stage 1 — synthetic test accounts + demo groups (CHECKPOINT 1, 2026-09-02)

Ran `pwsh -File scripts/create-test-users.ps1` (defaults) against tenant
`<TENANT_ID>` (contoso.onmicrosoft.com) as `user@contoso.com`.
Delegated consent granted for `User.ReadWrite.All`, `Group.ReadWrite.All`,
`Organization.Read.All`.

**Created (idempotent, existence-guarded):**

| Object | Id |
|---|---|
| User `offboard-test-1@contoso.com` ("Offboard Test 1") | `<PRINCIPAL_ID>` |
| User `offboard-test-2@contoso.com` ("Offboard Test 2") | `<PRINCIPAL_ID>` |
| User `offboard-test-3@contoso.com` ("Offboard Test 3") | `<PRINCIPAL_ID>` |
| Group `Offboarding Demo - Static` (assigned security group; all 3 users are members) | `<GROUP_ID>` |
| Licence `FLOW_FREE` (`f30db892-07e9-47e9-837c-80727f46fd3d`) | assigned to all 3 users (10000 units, 4 consumed) |

**Failed:** `Offboarding Demo - Dynamic` — `New-MgGroup` returned
`400 BadRequest / NoLicenseForOperation`. Dynamic-membership groups are an Entra ID
P1 feature; the tenant's SKUs are `FLOW_FREE`, `CCIBOTS_PRIVPREV_VIRAL`,
`O365_BUSINESS_ESSENTIALS` — no P1/P2.

**Decision — dropped the dynamic demo group.** A 30-day P1 trial would let a live
run demonstrate the skip, but it expires and leaves a broken group behind, which is
the wrong trade for a portfolio piece that may be shown months later. The runbook's
`Remove-TargetGroupMemberships` step already detects `groupTypes -contains
'DynamicMembership'` (or a non-null `membershipRuleProcessingState`) and logs a
`WARN` skip without attempting removal — this path is asserted by
`runbook/tests/Invoke-Offboarding.Tests.ps1` ("removes static groups and skips
dynamic ones"). `scripts/create-test-users.ps1`, its Pester tests, and the plan were
updated to remove the dynamic group; `docs/architecture.md` will note the design
(Task 16). CHECKPOINT 1 is complete with the static group only.

**AZ-104 note.** Dynamic groups sit behind Entra ID P1 — the same premium tier that
gates Conditional Access, PIM, and group-based licensing. Worth stating in the
identity-governance section: "least privilege" and "premium-gated" are different
axes, and a design that must run in a free/E-plan tenant can't assume rule-based
groups exist.

### Stage 2 — grant the MI its Graph app roles (CHECKPOINT 2, 2026-09-02)

> Numbered "2" by checkpoint, but **run after Stage 3** — the grant target is the
> Automation Account's managed identity, which doesn't exist until `azd provision`.

Ran `pwsh -File scripts/grant-managed-identity-graph-permissions.ps1
-AutomationAccountName aa-offboarding-dev -ResourceGroupName rg-offboarding-dev
-PrincipalId <PRINCIPAL_ID>`. Interactive delegated sign-in
consented the Microsoft Graph Command Line Tools app to `Application.Read.All` +
`AppRoleAssignment.ReadWrite.All` (org-wide). Grant performed by a Global
Administrator session.

**Three application app-role assignments created on MI SP
`<PRINCIPAL_ID>` → resource "Microsoft Graph"
(`00000003-0000-0000-c000-000000000000`), and nothing else:**

| Permission | appRoleId | assignment id | used by |
|---|---|---|---|
| `User.ReadWrite.All` | `741f803b-c850-494e-b5df-cde7c675a1ca` | `<APP_ROLE_ASSIGNMENT_ID>` | disable account, revoke sessions |
| `GroupMember.ReadWrite.All` | `dbaae8cf-10b5-4b86-a4a1-f871c94c6695` | `<APP_ROLE_ASSIGNMENT_ID>` | remove manual group memberships |
| `Organization.Read.All` | `498476ce-e0fe-48b0-b801-37ba7e2685c6` | `<APP_ROLE_ASSIGNMENT_ID>` | read tenant SKUs for the licence step |

All three `createdDateTime` `2026-09-02T05:16:5x`. Verified with
`GET /servicePrincipals/{id}/appRoleAssignments` — exactly 3, no extras. Script is
idempotent (a re-run reported nothing to do on `-WhatIfOnly`).

**Pre-req hit (again):** `Get-MgServicePrincipal` / `...AppRoleAssignment` live in
`Microsoft.Graph.Applications`, which was missing locally like
`Microsoft.Graph.Authentication` was at Stage 1. Installed at 2.32.0.

**Role note.** `User.ReadWrite.All` and `GroupMember.ReadWrite.All` as *application*
permissions are on Entra's privileged-permission list, so Application Administrator
/ Cloud Application Administrator can't consent to them — the grant needs Global
Administrator or Privileged Role Administrator. This is the single most privileged
operation in the project: afterwards the MI can read/write every user and every
group membership in the tenant, standing, with no runtime prompt. That's why the
permission set is a hard ceiling of three and the grant is its own checkpoint.

~10–20 min propagation before the runbook can use them (Task 13 Step 6 waits on
this).

### Stage 3 — first `azd provision` (CHECKPOINT 3, 2026-09-02)

Ran `azd provision --no-prompt` against `LVN Subscription`
(`<SUBSCRIPTION_ID>`) / `eastus2`. Deployment
`offboarding-dev-1788325232` — **Succeeded, all 10 resources**.

| Output | Value |
|---|---|
| `AZURE_RESOURCE_GROUP` | `rg-offboarding-dev` |
| `AUTOMATION_ACCOUNT_NAME` | `aa-offboarding-dev` (Free SKU, SystemAssigned MI) |
| `AUTOMATION_MI_PRINCIPAL_ID` | `<PRINCIPAL_ID>` |
| MI service principal | appId `<CLIENT_ID>`, displayName `aa-offboarding-dev` |
| `RUNBOOK_NAME` | `Invoke-Offboarding` — state **Published** |
| `LOG_ANALYTICS_WORKSPACE_NAME` | `log-offboarding-dev` (30-day retention, 1 GB/day cap) |

- **5 Graph PS7.2 modules** — `Microsoft.Graph.Authentication`, `.Users`,
  `.Users.Actions`, `.Groups`, `.Identity.DirectoryManagement` — all
  `provisioningState: Succeeded`, v2.39.0, account-scoped (`isGlobal: false`).
  Imports finished within the provision window (no lingering "Importing" state).
- **postprovision hook ran** — `scripts/publish-runbook.ps1` pushed
  `runbook/Invoke-Offboarding.ps1` and published it. `azd` does not echo hook
  stdout when `interactive: false`, but the runbook's published content matches the
  local file (8761 vs 8443 bytes — CRLF vs LF only) and `state` is `Published`.
- **Diagnostic setting** `to-log-analytics` — `JobLogs` + `JobStreams` → the
  workspace. Confirmed via `az rest` (the `az monitor diagnostic-settings` CLI
  choked on the nested Automation resource id).

**azd pre-validation false positive.** `azd` warned *"Resource
'…/Microsoft.Graph.Authentication' contains the reserved word 'MICROSOFT' … The
deployment will fail"* for all five module resources. It did **not** fail — the
PS-module resource name legitimately *is* the module name, and ARM accepts it. The
warning is `azd`'s client-side name linter being overzealous about the
`reserved-resource-name` rule; safe to ignore for `powerShell72Modules` children.

**Empty-runbook create worked.** The Bicep `runbooks` resource carries no
`draft`/`draftContentLink`. ARM created it fine (state `New` until the hook
published it) — the plan's earlier worry about needing a single-space placeholder
didn't materialise on API version `2023-11-01`.

Next: CHECKPOINT 2 — grant the MI (`<PRINCIPAL_ID>`) the three Graph app roles.

### Stage 4 — first end-to-end runbook run (2026-09-02)

First real job (`<JOB_ID>`, target `offboard-test-1@contoso.com`) reported
**Failed** with `Index operation failed; the array index evaluated to null` and
produced no output streams — but the tenant showed the account had already been
**disabled, de-licensed, and removed from the static group**. The Graph steps all
succeeded; the crash was in the run-summary aggregation.

Two throwaway diagnostic runbooks (`diag-hello`, `diag-graph2`, since deleted)
isolated it: the PowerShell 7.2 sandbox is healthy, and `Connect-MgGraph -Identity`
returns a token carrying **exactly** `User.ReadWrite.All`, `GroupMember.ReadWrite.All`,
`Organization.Read.All` — CHECKPOINT 2 has fully propagated.

**Root cause — three defects:**

1. `Write-RunLog` wrote log lines to the **success stream** (`Write-Output`). Every
   step that did work leaked its log string into `$results`; `Get-RunSummary` then
   evaluated `$counts[$r.Status]` where `$r.Status` on a string is `$null` →
   `$counts[$null]` → the index error. Noop-only paths never hit it, so the unit
   tests (which mock `Write-RunLog`) stayed green.
2. The entrypoint piped `Invoke-Offboarding | Out-Null`, discarding the JSON
   summary even on a clean run — the runbook could never emit job output.
3. `logVerbose: true` plus reliance on Graph module **auto-loading** produced
   ~5,000 module-import lines per job, stressing stream finalisation.

**Fixes (this commit):**

- `Write-RunLog` → **Information stream** (`Write-Information … -InformationAction Continue`);
  the four mutating Graph calls piped to `Out-Null`; `Get-RunSummary` guards
  `$counts.ContainsKey($r.Status)`.
- Entrypoint explicitly `Import-Module`s the five Graph sub-modules and emits
  `$summary | ConvertTo-Json -Depth 6` as job output.
- `infra/resources.bicep`: runbook `logVerbose` / `logProgress` → `false`.
- Pester 35/35 (one test added — `Write-RunLog` must not touch the pipeline),
  PSScriptAnalyzer + `bicep build`/`lint` clean.

Re-provisioned (`logVerbose` change) and re-published the runbook content;
re-ran `scripts/create-test-users.ps1` to restore `offboard-test-1`.

**Next (deferred to next session — usage cap): re-run the end-to-end test** —
test-1 full offboard, test-2 full offboard, a missing UPN (clean fail), test-1
again (idempotent all-noop) → capture `docs/sample-run.json`.

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
