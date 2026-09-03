#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Build-StatusJson.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bsj-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:WorkDir | Out-Null
}

AfterAll {
    Remove-Item -Recurse -Force $script:WorkDir -ErrorAction SilentlyContinue
}

Describe 'Build-StatusJson' {

    It 'maps a completed run to status ok with the contract shape' {
        $in = Join-Path $script:WorkDir 'completed.json'
        $out = Join-Path $script:WorkDir 'status-ok.json'
        @{
            TargetUpn       = 'offboard-test-1@contoso.com'
            RunTimestampUtc = '2026-09-02T15:23:40.7454248Z'
            Counts          = @{ succeeded = 4; failed = 0; skipped = 0; noop = 0 }
            OverallStatus   = 'completed'
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $in

        & $script:ScriptPath -RunSummaryPath $in -OutputPath $out

        # Assert the timestamp fields against the raw text - ConvertFrom-Json
        # silently re-parses ISO date strings into [datetime], which would hide
        # whether the file actually holds second-precision Z-suffixed strings.
        $text = Get-Content $out -Raw
        $text | Should -Match '"last_run_at": "2026-09-02T15:23:40Z"'
        $text | Should -Match '"generated_at": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'

        $s = $text | ConvertFrom-Json
        $s.schema_version | Should -Be 1
        $s.project        | Should -Be 'm365-offboarding-automator'
        $s.cadence        | Should -Be 'on-demand'
        $s.status         | Should -Be 'ok'
        $s.detail.target  | Should -Be 'offboard-test-1@contoso.com'
        $s.detail.overall | Should -Be 'completed'
        $s.detail.steps.succeeded | Should -Be 4
        $s.headline       | Should -Not -Match '\$'
    }

    It 'maps completed_with_failures to status error' {
        $in = Join-Path $script:WorkDir 'failed.json'
        $out = Join-Path $script:WorkDir 'status-err.json'
        @{
            TargetUpn       = 'nope@contoso.com'
            RunTimestampUtc = '2026-09-02T15:26:30.2651010Z'
            Counts          = @{ succeeded = 0; failed = 1; skipped = 0; noop = 0 }
            OverallStatus   = 'completed_with_failures'
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $in

        & $script:ScriptPath -RunSummaryPath $in -OutputPath $out

        $s = Get-Content $out -Raw | ConvertFrom-Json
        $s.status               | Should -Be 'error'
        $s.detail.steps.failed  | Should -Be 1
    }

    It 'takes the last run when given a runs array (sample-run.json shape)' {
        $in = Join-Path $script:WorkDir 'multi.json'
        $out = Join-Path $script:WorkDir 'status-multi.json'
        @{
            runs = @(
                @{ TargetUpn = 'a@contoso.com'; RunTimestampUtc = '2026-09-02T15:23:40.7Z'
                    Counts = @{ succeeded = 4; failed = 0; skipped = 0; noop = 0 }; OverallStatus = 'completed' },
                @{ TargetUpn = 'b@contoso.com'; RunTimestampUtc = '2026-09-02T15:25:12.4Z'
                    Counts = @{ succeeded = 1; failed = 0; skipped = 1; noop = 2 }; OverallStatus = 'completed' }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $in

        & $script:ScriptPath -RunSummaryPath $in -OutputPath $out

        $s = Get-Content $out -Raw | ConvertFrom-Json
        $s.detail.target        | Should -Be 'b@contoso.com'
        $s.detail.steps.noop    | Should -Be 2
    }
}
