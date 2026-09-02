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
