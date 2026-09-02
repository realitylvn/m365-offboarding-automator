BeforeAll {
    . "$PSScriptRoot/GraphStubs.ps1"
    $script:ScriptPath = (Resolve-Path "$PSScriptRoot/../../scripts/create-test-users.ps1").Path
}

Describe 'create-test-users.ps1' {
    BeforeEach {
        Mock Connect-MgGraph {}
        Mock Get-MgOrganization { [pscustomobject]@{ VerifiedDomains = @([pscustomobject]@{ Name = 'contoso.com'; IsDefault = $true }) } }
        Mock Get-MgUser {}
        Mock New-MgUser { [pscustomobject]@{ Id = "id-$UserPrincipalName"; UserPrincipalName = $UserPrincipalName } }
        Mock Get-MgSubscribedSku {}
        Mock Set-MgUserLicense {}
        Mock Get-MgGroup {}
        Mock New-MgGroup { [pscustomobject]@{ Id = "grp-$($DisplayName -replace '\W', '')"; DisplayName = $DisplayName } }
        Mock New-MgGroupMember {}
        Mock Get-MgGroupMember { @() }
    }

    Context '-WhatIfOnly' {
        It 'lists every planned UPN and makes no Graph calls at all' {
            $out = & $script:ScriptPath -Count 3 -WhatIfOnly
            Should -Invoke Connect-MgGraph -Times 0
            Should -Invoke Get-MgOrganization -Times 0
            Should -Invoke New-MgUser -Times 0
            Should -Invoke New-MgGroup -Times 0
            Should -Invoke Set-MgUserLicense -Times 0
            ($out | Out-String) | Should -Match 'offboard-test-1@<tenant-primary-domain>'
            ($out | Out-String) | Should -Match 'offboard-test-3@<tenant-primary-domain>'
        }
    }

    Context 'live run against an empty tenant' {
        It 'connects with exactly the three least-privilege scopes' {
            & $script:ScriptPath -Count 1
            Should -Invoke Connect-MgGraph -Times 1 -ParameterFilter {
                ($Scopes -contains 'User.ReadWrite.All') -and
                ($Scopes -contains 'Group.ReadWrite.All') -and
                ($Scopes -contains 'Organization.Read.All') -and
                ($Scopes.Count -eq 3)
            }
        }
        It 'creates every missing user and the one assigned demo group' {
            & $script:ScriptPath -Count 2
            Should -Invoke New-MgUser -Times 2 -ParameterFilter { $UserPrincipalName -eq 'offboard-test-1@contoso.com' -or $UserPrincipalName -eq 'offboard-test-2@contoso.com' }
            Should -Invoke New-MgGroup -Times 1
            Should -Invoke New-MgGroup -Times 0 -ParameterFilter { $GroupTypes -contains 'DynamicMembership' }
        }
        It 'adds each created user to the static group' {
            & $script:ScriptPath -Count 2
            Should -Invoke New-MgGroupMember -Times 2
        }
        It 'assigns the license only when the SKU exists with a free unit' {
            Mock Get-MgSubscribedSku {
                @([pscustomobject]@{ SkuId = 'sku-flow'; SkuPartNumber = 'FLOW_FREE'; PrepaidUnits = [pscustomobject]@{ Enabled = 10000 }; ConsumedUnits = 5 })
            }
            & $script:ScriptPath -Count 1
            Should -Invoke Set-MgUserLicense -Times 1 -ParameterFilter {
                ($AddLicenses.SkuId -contains 'sku-flow') -and $RemoveLicenses.Count -eq 0
            }
        }
        It 'skips the license step when the SKU is not present in the tenant' {
            Mock Get-MgSubscribedSku { @() }
            & $script:ScriptPath -Count 1
            Should -Invoke Set-MgUserLicense -Times 0
        }
    }

    Context 'idempotency' {
        It 'creates nothing when the users and groups already exist' {
            Mock Get-MgUser { [pscustomobject]@{ Id = 'existing-user'; UserPrincipalName = 'offboard-test-1@contoso.com' } }
            Mock Get-MgGroup { [pscustomobject]@{ Id = 'existing-grp'; DisplayName = 'existing' } }
            & $script:ScriptPath -Count 1
            Should -Invoke New-MgUser -Times 0
            Should -Invoke New-MgGroup -Times 0
        }
    }
}
