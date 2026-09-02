#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
$ErrorActionPreference = 'Stop'
$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.Exit = $true
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $PSScriptRoot 'testResults.xml'
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
