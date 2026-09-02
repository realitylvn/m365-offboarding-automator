BeforeAll {
    . "$PSScriptRoot/GraphStubs.ps1"
    $script:ScriptPath = (Resolve-Path "$PSScriptRoot/../../scripts/grant-managed-identity-graph-permissions.ps1").Path
    $script:GraphAppId = '00000003-0000-0000-c000-000000000000'
}

Describe 'grant-managed-identity-graph-permissions.ps1' {
    BeforeEach {
        Mock Connect-MgGraph {}
        Mock Get-MgServicePrincipal {
            if ($Filter -like "*$script:GraphAppId*") {
                [pscustomobject]@{ Id = 'graph-sp'; AppRoles = @(
                        [pscustomobject]@{ Id = 'role-user-rw'; Value = 'User.ReadWrite.All'; AllowedMemberTypes = @('Application') }
                        [pscustomobject]@{ Id = 'role-grp-rw'; Value = 'GroupMember.ReadWrite.All'; AllowedMemberTypes = @('Application') }
                        [pscustomobject]@{ Id = 'role-org-read'; Value = 'Organization.Read.All'; AllowedMemberTypes = @('Application') }
                        [pscustomobject]@{ Id = 'role-deleg-only'; Value = 'Delegated.Thing'; AllowedMemberTypes = @('User') }
                    ) }
            }
            else {
                [pscustomobject]@{ Id = 'mi-sp'; DisplayName = 'aa-offboarding-dev'; AppRoles = @() }
            }
        }
        Mock Get-MgServicePrincipalAppRoleAssignment { @() }
        Mock New-MgServicePrincipalAppRoleAssignment {}
    }

    It 'grants all three roles when none are present' {
        & $script:ScriptPath -AutomationAccountName 'aa-offboarding-dev'
        Should -Invoke New-MgServicePrincipalAppRoleAssignment -Times 3
        Should -Invoke New-MgServicePrincipalAppRoleAssignment -Times 1 -ParameterFilter {
            $ServicePrincipalId -eq 'mi-sp' -and $PrincipalId -eq 'mi-sp' -and $ResourceId -eq 'graph-sp' -and $AppRoleId -eq 'role-user-rw'
        }
    }

    It 'connects with only the two consent scopes it needs' {
        & $script:ScriptPath -AutomationAccountName 'aa-offboarding-dev'
        Should -Invoke Connect-MgGraph -Times 1 -ParameterFilter {
            ($Scopes -contains 'Application.Read.All') -and ($Scopes -contains 'AppRoleAssignment.ReadWrite.All') -and ($Scopes.Count -eq 2)
        }
    }

    It 'is a no-op for a role that is already assigned' {
        Mock Get-MgServicePrincipalAppRoleAssignment { @([pscustomobject]@{ AppRoleId = 'role-user-rw' }) }
        & $script:ScriptPath -AutomationAccountName 'aa-offboarding-dev'
        Should -Invoke New-MgServicePrincipalAppRoleAssignment -Times 2
    }

    It 'writes nothing under -WhatIfOnly' {
        & $script:ScriptPath -AutomationAccountName 'aa-offboarding-dev' -WhatIfOnly
        Should -Invoke New-MgServicePrincipalAppRoleAssignment -Times 0
    }

    It 'throws when the managed-identity service principal cannot be uniquely resolved' {
        Mock Get-MgServicePrincipal {
            if ($Filter -like "*$script:GraphAppId*") { [pscustomobject]@{ Id = 'graph-sp'; AppRoles = @() } }
            else { @() }
        }
        { & $script:ScriptPath -AutomationAccountName 'does-not-exist' } | Should -Throw '*PrincipalId*'
    }

    It 'uses an explicit -PrincipalId without a displayName lookup' {
        Mock Get-MgServicePrincipal {
            if ($Filter -like "*$script:GraphAppId*") {
                [pscustomobject]@{ Id = 'graph-sp'; AppRoles = @(
                        [pscustomobject]@{ Id = 'role-user-rw'; Value = 'User.ReadWrite.All'; AllowedMemberTypes = @('Application') }
                        [pscustomobject]@{ Id = 'role-grp-rw'; Value = 'GroupMember.ReadWrite.All'; AllowedMemberTypes = @('Application') }
                        [pscustomobject]@{ Id = 'role-org-read'; Value = 'Organization.Read.All'; AllowedMemberTypes = @('Application') }
                    ) }
            }
            else { [pscustomobject]@{ Id = $ServicePrincipalId; AppRoles = @() } }
        }
        & $script:ScriptPath -AutomationAccountName 'aa-offboarding-dev' -PrincipalId 'explicit-mi-oid'
        Should -Invoke Get-MgServicePrincipal -Times 0 -ParameterFilter { $Filter -like 'displayName*' }
        Should -Invoke New-MgServicePrincipalAppRoleAssignment -Times 3 -ParameterFilter { $ServicePrincipalId -eq 'explicit-mi-oid' }
    }

    It 'reports a permission whose app role does not exist on the Graph SP without throwing' {
        { & $script:ScriptPath -AutomationAccountName 'aa-offboarding-dev' -GraphPermissions @('User.ReadWrite.All', 'Made.Up.Scope') } | Should -Not -Throw
        Should -Invoke New-MgServicePrincipalAppRoleAssignment -Times 1
    }
}
