# Stand-ins for Microsoft.Graph cmdlets so the runbook loads and Pester can Mock
# them (with -ParameterFilter) on a machine that has no Graph SDK installed.
# Parameters mirror only what runbook/Invoke-Offboarding.ps1 passes.

function Connect-MgGraph { param([switch]$Identity, [string[]]$Scopes, [switch]$NoWelcome) }
function Get-MgUser { param([string]$UserId, [string]$Filter, [string[]]$Property, [switch]$All, [string]$ConsistencyLevel) }
function Update-MgUser { param([string]$UserId, [bool]$AccountEnabled, [hashtable]$BodyParameter) }
function Revoke-MgUserSignInSession { param([string]$UserId) }
function Get-MgUserLicenseDetail { param([string]$UserId, [switch]$All) }
function Set-MgUserLicense { param([string]$UserId, [array]$AddLicenses, [array]$RemoveLicenses, [hashtable]$BodyParameter) }
function Get-MgUserMemberOf { param([string]$UserId, [switch]$All, [string[]]$Property) }
function Get-MgGroup { param([string]$GroupId, [string]$Filter, [switch]$All, [string[]]$Property) }
function Remove-MgGroupMemberByRef { param([string]$GroupId, [string]$DirectoryObjectId) }
function Get-MgSubscribedSku { param([switch]$All) }

# --- setup-script cmdlets (scripts/create-test-users.ps1) ---
function New-MgUser { param([string]$DisplayName, [string]$UserPrincipalName, [string]$MailNickname, [bool]$AccountEnabled, [hashtable]$PasswordProfile, [string]$UsageLocation) }
function New-MgGroup { param([string]$DisplayName, [string]$MailNickname, [string]$Description, [bool]$SecurityEnabled, [bool]$MailEnabled, [string[]]$GroupTypes, [string]$MembershipRule, [string]$MembershipRuleProcessingState) }
function New-MgGroupMember { param([string]$GroupId, [string]$DirectoryObjectId) }
function Get-MgGroupMember { param([string]$GroupId, [switch]$All) }
