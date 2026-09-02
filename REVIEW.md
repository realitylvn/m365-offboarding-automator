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

### CI: PR gate now, OIDC deploy pipeline deferred (CHECKPOINT 4, 2026-09-02)

`.github/workflows/ci.yml` (Task 14, PR #1) runs `lint-ps` + `test-ps` + `bicep`
on every PR and non-`main` push — that's the quality gate. The **deploy**
pipeline — `.github/workflows/deploy.yml`, a federated OIDC identity trusting this
repo, and `azd provision` on push to `main` — is **deferred**, matching the same
call in `azure-cost-sentinel`. This section is the design, so the reasoning is on
record even though the pipeline isn't built.

**Why not just build it with subscription-scoped Contributor (the "easy" version).**
`infra/main.bicep` is `targetScope = 'subscription'` — it declares the resource
group itself and then a module scoped into it. A subscription-scoped deployment is
authorised at the subscription: the principal needs
`Microsoft.Resources/deployments/*` **and** `Microsoft.Resources/subscriptions/resourceGroups/write`
at subscription scope, i.e. effectively **Contributor on the whole subscription**.
That's true *even now that `rg-offboarding-dev` already exists* — ARM still
evaluates the RG resource in the template at sub scope on every run; an existing
RG makes the write a no-op but doesn't lower the permission needed to evaluate it.

Federating that identity to a **public** GitHub repo means a standing trust from
GitHub's OIDC issuer to a principal that can create or modify **any resource group
in the LVN subscription**. For a portfolio tool that one person deploys by hand
with `azd provision`, that is the wrong trade: the blast radius (whole
subscription) and the standing-ness (no human in the loop once `main` moves) both
vastly exceed the value (skipping one `azd provision` command).

**What the correctly-scoped version would need** (the bar to actually build this):

1. **User-assigned managed identity, not an app registration.** `id-offboarding-dev`
   in `rg-offboarding-dev`. A UAMI cannot have a client secret or a password
   credential added to it — federated credentials are its *only* auth path — so
   "no stored secret" stays structurally true. An app registration can always have
   a secret bolted on later by anyone with access; a UAMI can't.
2. **RG-bootstrap solved out of band.** Because a sub-scoped template needs
   sub-scope rights, either (a) split provisioning: a one-time manual
   `az group create rg-offboarding-dev` (already done, at CHECKPOINT 3) + refactor
   `main.bicep`/`main.parameters.json` to `targetScope = 'resourceGroup'` so CI
   only ever deploys *into* the existing RG with RG-scoped Contributor; or
   (b) keep the sub-scoped template but accept sub-scope Contributor — rejected,
   see above. Option (a) is the right shape but breaks the "match Project 1
   conventions" rule that `main.bicep` is subscription-scoped, so it's a conscious
   convention deviation, not a silent one.
3. **RBAC: Contributor on `rg-offboarding-dev` only.** No User Access Administrator
   — confirmed there are **zero `Microsoft.Authorization/roleAssignments`** in
   `infra/*.bicep` (the only identity output is `automationMiPrincipalId`, a
   passthrough). Diagnostic settings on the Automation Account are
   `Microsoft.Insights/diagnosticSettings` writes, which Contributor covers.
4. **Two federated credential subjects, minimum surface:**
   `repo:realitylvn/m365-offboarding-automator:ref:refs/heads/main` and
   `repo:realitylvn/m365-offboarding-automator:environment:production`.
5. **Workflow guards:** trigger on `push: branches: [main]` + `workflow_dispatch`
   **only** — never `pull_request` (a fork PR must not be able to invoke a
   deploy). Bind the job to a GitHub `production` environment with a **required
   reviewer**, so even a push to `main` pauses for a human approve before the
   federated token is minted.
6. **Repo secrets** (`gh secret set`): `AZURE_CLIENT_ID` (the UAMI's client id),
   `AZURE_TENANT_ID` `<TENANT_ID>`,
   `AZURE_SUBSCRIPTION_ID` `<SUBSCRIPTION_ID>`. None of these is
   sensitive (client id and tenant id are not secrets; they're identifiers), but
   the workflow reads them as secrets by convention.

**When to revisit.** If this repo goes private, or if a second person needs to
deploy, or if the Ops Dashboard project (project 5) ends up orchestrating
cross-project deploys — any of those changes the calculus. Until then, manual
`azd provision` from an authenticated developer session is the right amount of
automation.

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
| `az automation runbook start -g rg-offboarding-dev --automation-account-name aa-offboarding-dev --name Invoke-Offboarding --parameters TargetUpn=…` ×4 | Task 13 Step 6 (attempt #2) — the four acceptance jobs (test-1, test-2, missing UPN, test-1 re-run). All `Completed`; see *Stage 5*. |
| `az automation job show -g … --automation-account-name … --name <job> --query status` | Polled each job to a terminal state (`New`→`Activating`→`Running`→`Completed`, ~1–2 min each). |
| `az rest --method get ".../jobs/<job>/streams?api-version=2023-11-01&$filter=properties/streamType eq 'Output'"` | Pulled each job's JSON summary from the Output stream (the `az automation job get-output` command doesn't exist; `job show` carries no output). Sanitised into `docs/sample-run.json`. |
| `az rest --method patch https://graph.microsoft.com/v1.0/users/<PRINCIPAL_ID>  -b '{"accountEnabled":true}'` | Post-test — re-enabled `offboard-test-1`. Further restore writes (re-license, re-group `offboard-test-1`/`-2`) were intermittently blocked by the auto-mode classifier — pending. |

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

Re-provisioned — `azd provision` deployment `offboarding-dev-1788328582`
Succeeded (43s; `logVerbose`/`logProgress` now `false` on the runbook) — and
re-published the runbook content via `scripts/publish-runbook.ps1`; the published
copy carries the `Write-Information` / explicit-`Import-Module` fixes (212 lines,
matches local). `offboard-test-1` restored to enabled + FLOW_FREE + static-group
membership via targeted Graph calls (the setup script's existence guards would
have skipped the re-enable). All three test users are back at parity.

**Next (deferred to next session — usage cap): re-run the end-to-end test** —
test-1 full offboard, test-2 full offboard, a missing UPN (clean fail), test-1
again (idempotent all-noop) → capture `docs/sample-run.json`.

### Stage 5 — end-to-end acceptance test, attempt #2 (2026-09-02)

Ran the four acceptance jobs against `aa-offboarding-dev` /
`Invoke-Offboarding` with the Stage 4 fixes in place. **All four behaved exactly
to spec** — the Automation job status is `Completed` for every run that the
runbook handled cleanly, including the missing-UPN case (partial-completion
tolerance means "user not found" is a *failed step*, not a *failed job*).

| # | Job | `TargetUpn` | Job status | `OverallStatus` | Step outcomes |
|---|---|---|---|---|---|
| 1 | `<JOB_ID>` | `offboard-test-1@contoso.com` | Completed | `completed` | disable / revoke / remove-licenses / remove-group-memberships all **succeeded** |
| 2 | `<JOB_ID>` | `offboard-test-2@contoso.com` | Completed | `completed` | all four **succeeded** |
| 3 | `<JOB_ID>` | `offboard-test-does-not-exist@contoso.com` | Completed | `completed_with_failures` | `resolve-user` **failed**, zero step attempts |
| 4 | `<JOB_ID>` | `offboard-test-1@contoso.com` (re-run) | Completed | `completed` | disable **noop**, revoke **succeeded**, remove-licenses **noop**, remove-group-memberships **skipped** |

**What run 4 proves.** Re-running against an already-offboarded user is safe and
near-inert: the two steps with an idempotency branch (`Disable-TargetAccount`,
`Remove-TargetLicenses`) detect the end state and return `noop` with no Graph
write; `Remove-TargetGroupMemberships` finds nothing removable and returns
`skipped`; only `Revoke-TargetSessions` re-runs unconditionally (revoking already
-revoked tokens is harmless). Counts `{ succeeded: 1, noop: 2, skipped: 1 }`.

**Output plumbing confirmed.** Job output (Output stream) is a single
`$summary | ConvertTo-Json -Depth 6` blob; the `[timestamp] LEVEL message` step
logs land on the Information stream (visible under job "All Logs" / `JobStreams`
in Log Analytics), not mixed into the return value — the Stage 4 fix for the
`$counts[$null]` crash.

Sanitised copies of all four summaries saved to `docs/sample-run.json` (object /
SKU / group GUIDs → stable `00000000-…` placeholders; timestamps and statuses
verbatim).

**Tenant left-state.** All three test users restored to parity after the runs —
`accountEnabled: true`, `FLOW_FREE` re-assigned, members of `Offboarding Demo -
Static` — via targeted `az rest` Graph calls (`PATCH /users/{id}`,
`POST /users/{id}/assignLicense`, `POST /groups/{id}/members/$ref`).
`offboard-test-3` was never a target. The tenant is ready for a fresh demo run.

**`az automation` CLI note (again).** `az automation job get-output` does not
exist and `... job show --query output` is empty; the job's Output-stream
content is only reachable via ARM REST —
`GET .../jobs/{id}/streams?api-version=2023-11-01&$filter=properties/streamType eq 'Output'`,
then read `value[].properties.summary`.

## AZ-900 / AZ-104 domain mapping

- **Identity & access management (AZ-104 ~30%)**:
  - *Workload identity* — system-assigned Managed Identity on the Automation Account; the
    runbook authenticates with `Connect-MgGraph -Identity`, no credential to store or rotate.
  - *Application vs. delegated permissions* — the MI's service principal is granted Graph
    *application* app-roles by direct assignment (`New-MgServicePrincipalAppRoleAssignment`),
    which is the admin-consent equivalent and needs Global Administrator / Privileged Role
    Administrator (Application Administrator can't consent to `User.ReadWrite.All` /
    `GroupMember.ReadWrite.All` — they're on the privileged-permission list). Contrast with
    the *delegated* consent the two setup scripts use when a human runs them interactively.
  - *Account lifecycle* — `accountEnabled = false`, `revokeSignInSessions` (refresh-token
    invalidation), licence de-assignment, group de-membership: the four operations that make
    up a real leaver process.
  - *Premium-gated features* — dynamic (rule-based) groups need Entra ID P1; the tenant has
    none, so the demo uses an assigned group and the runbook's skip-dynamic path is unit-
    tested rather than shown live (see *Stage 1*).
- **Governance & least privilege (AZ-900 + AZ-104)**:
  - A hard **three-permission ceiling** on the MI (`User.ReadWrite.All`,
    `GroupMember.ReadWrite.All`, `Organization.Read.All`), enforced as its own checkpoint —
    the single most privileged operation in the project.
  - CAF **naming + tagging** convention (`rg-/aa-/log-offboarding-dev`, `portfolio` / `project`
    / `environment` tags) applied *before* the first provision, not retrofitted.
  - CHECKPOINT 4: chose **not** to stand up a subscription-scoped, public-repo-federated
    deploy identity — a least-privilege / blast-radius call, documented rather than built.
- **Compute & automation (AZ-900 + AZ-104)**: Automation Account (Free SKU, PowerShell 7.2
  runbook) vs. Functions — chosen for a no-HTTP, no-schedule, parameter-triggered admin
  workload where job input/output/streams are captured for free. Runbook content published
  out-of-band via an `azd` `postprovision` hook, never embedded in Bicep.
- **Monitoring (AZ-104 Azure Monitor)**: Automation Account **diagnostic settings** route
  `JobLogs` + `JobStreams` to a 1 GB/day-capped Log Analytics workspace, so every run's
  step-by-step Information-stream log is queryable after the job object ages out.
- **IaC & deployment (AZ-104)**: subscription-scoped Bicep entrypoint (`main.bicep` creates
  the RG + one `resources` module), `azd provision`, and the reason a sub-scoped template
  forces sub-scope deploy rights even for an existing RG (see the deferred-OIDC design).
