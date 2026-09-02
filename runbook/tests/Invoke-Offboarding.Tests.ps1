BeforeAll {
    . "$PSScriptRoot/GraphStubs.ps1"
    . "$PSScriptRoot/../Invoke-Offboarding.ps1" -TargetUpn 'offboard-test-1@contoso.com' -LoadFunctionsOnly
}

Describe 'Write-RunLog' {
    It 'prefixes an ISO-8601 UTC timestamp and the level' {
        $line = Write-RunLog -Message 'hello' -Level 'WARN'
        $line | Should -Match '^\[\d{4}-\d{2}-\d{2}T[\d:.]+(Z|\+00:00)\] WARN hello$'
    }
    It 'defaults the level to INFO' {
        $line = Write-RunLog -Message 'plain'
        $line | Should -Match '\] INFO plain$'
    }
}

Describe 'New-StepResult' {
    It 'rejects a status outside the allowed set' {
        { New-StepResult -Step 'x' -Status 'bogus' -Message 'm' } | Should -Throw
    }
    It 'carries through step, status, message, detail' {
        $r = New-StepResult -Step 'disable-account' -Status 'succeeded' -Message 'ok' -Detail @{ userId = 'abc' }
        $r.Step | Should -Be 'disable-account'
        $r.Status | Should -Be 'succeeded'
        $r.Detail.userId | Should -Be 'abc'
        $r.TimestampUtc | Should -Match '\d{4}-\d{2}-\d{2}T'
    }
}

Describe 'Resolve-TargetUser' {
    It 'returns the user object when Graph finds it' {
        Mock Get-MgUser { [pscustomobject]@{ Id = 'u-1'; UserPrincipalName = 'offboard-test-1@contoso.com'; AccountEnabled = $true } }
        $u = Resolve-TargetUser -Upn 'offboard-test-1@contoso.com'
        $u.Id | Should -Be 'u-1'
    }
    It 'returns $null when Graph raises a not-found error' {
        Mock Get-MgUser { throw [System.Exception]::new('[Request_ResourceNotFound] : Resource "nope@contoso.com" does not exist') }
        Resolve-TargetUser -Upn 'nope@contoso.com' | Should -BeNullOrEmpty
    }
    It 're-throws a non-not-found error (e.g. throttling)' {
        Mock Get-MgUser { throw [System.Exception]::new('[TooManyRequests] : throttled') }
        { Resolve-TargetUser -Upn 'offboard-test-1@contoso.com' } | Should -Throw '*throttled*'
    }
}

Describe 'Disable-TargetAccount' {
    It 'disables an enabled account and returns succeeded' {
        Mock Update-MgUser {}
        $r = Disable-TargetAccount -User ([pscustomobject]@{ Id = 'u-1'; AccountEnabled = $true })
        Should -Invoke Update-MgUser -Times 1 -ParameterFilter { $UserId -eq 'u-1' -and $AccountEnabled -eq $false }
        $r.Step | Should -Be 'disable-account'
        $r.Status | Should -Be 'succeeded'
    }
    It 'is a no-op when the account is already disabled' {
        Mock Update-MgUser {}
        $r = Disable-TargetAccount -User ([pscustomobject]@{ Id = 'u-1'; AccountEnabled = $false })
        Should -Invoke Update-MgUser -Times 0
        $r.Status | Should -Be 'noop'
    }
}

Describe 'Revoke-TargetSessions' {
    It 'calls revokeSignInSession for the user and returns succeeded' {
        Mock Revoke-MgUserSignInSession {}
        $r = Revoke-TargetSessions -User ([pscustomobject]@{ Id = 'u-1'; UserPrincipalName = 'offboard-test-1@contoso.com' })
        Should -Invoke Revoke-MgUserSignInSession -Times 1 -ParameterFilter { $UserId -eq 'u-1' }
        $r.Step | Should -Be 'revoke-sessions'
        $r.Status | Should -Be 'succeeded'
    }
}

Describe 'Remove-TargetLicenses' {
    It 'removes every assigned SKU in one call' {
        Mock Get-MgUserLicenseDetail {
            @(
                [pscustomobject]@{ SkuId = 'sku-a'; SkuPartNumber = 'FLOW_FREE' }
                [pscustomobject]@{ SkuId = 'sku-b'; SkuPartNumber = 'POWER_BI_STANDARD' }
            )
        }
        Mock Set-MgUserLicense {}
        $r = Remove-TargetLicenses -User ([pscustomobject]@{ Id = 'u-1'; UserPrincipalName = 'offboard-test-1@contoso.com' })
        Should -Invoke Set-MgUserLicense -Times 1 -ParameterFilter {
            $UserId -eq 'u-1' -and $AddLicenses.Count -eq 0 -and
            ($RemoveLicenses -contains 'sku-a') -and ($RemoveLicenses -contains 'sku-b')
        }
        $r.Status | Should -Be 'succeeded'
        $r.Detail.removedSkus | Should -Contain 'sku-b'
    }
    It 'is a no-op when the user has no licenses' {
        Mock Get-MgUserLicenseDetail { @() }
        Mock Set-MgUserLicense {}
        $r = Remove-TargetLicenses -User ([pscustomobject]@{ Id = 'u-1'; UserPrincipalName = 'x@contoso.com' })
        Should -Invoke Set-MgUserLicense -Times 0
        $r.Status | Should -Be 'noop'
    }
}

Describe 'Remove-TargetGroupMemberships' {
    BeforeEach {
        $script:mkGroup = {
            param($id, $name, $dynamic)
            $ap = @{ '@odata.type' = '#microsoft.graph.group'; displayName = $name; groupTypes = @() }
            if ($dynamic) { $ap.groupTypes = @('DynamicMembership'); $ap.membershipRuleProcessingState = 'On' }
            [pscustomobject]@{ Id = $id; AdditionalProperties = $ap }
        }
    }
    It 'removes static groups and skips dynamic ones' {
        Mock Get-MgUserMemberOf {
            @(
                (& $script:mkGroup 'g-static-1' 'Sales'   $false),
                (& $script:mkGroup 'g-dynamic-1' 'AllUsers' $true),
                ([pscustomobject]@{ Id = 'role-1'; AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.directoryRole' } })
            )
        }
        Mock Remove-MgGroupMemberByRef {}
        $r = Remove-TargetGroupMemberships -User ([pscustomobject]@{ Id = 'u-1'; UserPrincipalName = 'offboard-test-1@contoso.com' })
        Should -Invoke Remove-MgGroupMemberByRef -Times 1 -ParameterFilter { $GroupId -eq 'g-static-1' -and $DirectoryObjectId -eq 'u-1' }
        $r.Status | Should -Be 'succeeded'
        $r.Detail.removed | Should -Contain 'g-static-1'
        $r.Detail.skippedDynamic | Should -Contain 'g-dynamic-1'
    }
    It 'continues past a failing group removal and marks the step failed' {
        Mock Get-MgUserMemberOf {
            @( (& $script:mkGroup 'g-1' 'A' $false), (& $script:mkGroup 'g-2' 'B' $false) )
        }
        Mock Remove-MgGroupMemberByRef { if ($GroupId -eq 'g-1') { throw 'boom' } }
        $r = Remove-TargetGroupMemberships -User ([pscustomobject]@{ Id = 'u-1'; UserPrincipalName = 'x@contoso.com' })
        Should -Invoke Remove-MgGroupMemberByRef -Times 2
        $r.Status | Should -Be 'failed'
        $r.Detail.removed | Should -Contain 'g-2'
        $r.Detail.failed  | Should -Contain 'g-1'
    }
    It 'is a no-op when the user is in no removable groups' {
        Mock Get-MgUserMemberOf { @( (& $script:mkGroup 'g-dynamic-1' 'AllUsers' $true) ) }
        Mock Remove-MgGroupMemberByRef {}
        $r = Remove-TargetGroupMemberships -User ([pscustomobject]@{ Id = 'u-1'; UserPrincipalName = 'x@contoso.com' })
        $r.Status | Should -Be 'skipped'
    }
}

Describe 'Get-RunSummary' {
    It 'tallies each status and reports completed_with_failures when any step failed' {
        $results = @(
            New-StepResult -Step 'a' -Status 'succeeded' -Message 'm'
            New-StepResult -Step 'b' -Status 'failed'    -Message 'm'
            New-StepResult -Step 'c' -Status 'skipped'   -Message 'm'
            New-StepResult -Step 'd' -Status 'noop'      -Message 'm'
        )
        $s = Get-RunSummary -TargetUpn 'offboard-test-1@contoso.com' -Results $results
        $s.Counts.succeeded | Should -Be 1
        $s.Counts.failed    | Should -Be 1
        $s.Counts.skipped   | Should -Be 1
        $s.Counts.noop      | Should -Be 1
        $s.OverallStatus    | Should -Be 'completed_with_failures'
    }
    It 'reports completed when nothing failed and accepts an empty result set' {
        $s = Get-RunSummary -TargetUpn 'x@contoso.com' -Results @()
        $s.OverallStatus | Should -Be 'completed'
        $s.Counts.succeeded | Should -Be 0
    }
}

Describe 'Invoke-Offboarding (orchestration)' {
    BeforeEach {
        Mock Connect-MgGraph {}
        Mock Write-RunLog {}
    }
    It 'exits cleanly with no step attempts when the user does not exist' {
        Mock Resolve-TargetUser { $null }
        Mock Disable-TargetAccount {}
        $s = Invoke-Offboarding -TargetUpn 'nope@contoso.com' -SkipConnect
        Should -Invoke Disable-TargetAccount -Times 0
        $s.Steps.Step | Should -Be 'resolve-user'
        $s.OverallStatus | Should -Be 'completed_with_failures'
    }
    It 'runs all four steps and aggregates a mixed result' {
        Mock Resolve-TargetUser { [pscustomobject]@{ Id = 'u-1'; UserPrincipalName = 'offboard-test-1@contoso.com'; AccountEnabled = $true } }
        Mock Disable-TargetAccount        { New-StepResult -Step 'disable-account' -Status 'succeeded' -Message 'm' }
        Mock Revoke-TargetSessions        { New-StepResult -Step 'revoke-sessions' -Status 'succeeded' -Message 'm' }
        Mock Remove-TargetLicenses        { throw 'graph 500' }
        Mock Remove-TargetGroupMemberships { New-StepResult -Step 'remove-group-memberships' -Status 'skipped' -Message 'm' }
        $s = Invoke-Offboarding -TargetUpn 'offboard-test-1@contoso.com' -SkipConnect
        $s.Counts.succeeded | Should -Be 2
        $s.Counts.failed    | Should -Be 1
        $s.Counts.skipped   | Should -Be 1
        ($s.Steps | Where-Object Step -eq 'remove-licenses').Status | Should -Be 'failed'
        $s.OverallStatus | Should -Be 'completed_with_failures'
    }
    It 'connects with -Identity when -SkipConnect is not passed' {
        Mock Resolve-TargetUser { $null }
        Invoke-Offboarding -TargetUpn 'x@contoso.com' | Out-Null
        Should -Invoke Connect-MgGraph -Times 1 -ParameterFilter { $Identity -eq $true }
    }
}
